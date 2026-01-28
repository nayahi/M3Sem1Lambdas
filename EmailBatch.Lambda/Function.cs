using Amazon.Lambda.Core;
using Amazon.Lambda.SQSEvents;
using ECommerceGRPC.NotificationService;
using Grpc.Core;
using Grpc.Net.Client;
using Polly;
using Polly.CircuitBreaker;
using Polly.Retry;
using Polly.Timeout;
using System.Text.Json;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace EmailBatch.Lambda;

public class Function
{
    // gRPC client lazy initialization
    private static Lazy<NotificationService.NotificationServiceClient> _lazyNotificationClient =
        new Lazy<NotificationService.NotificationServiceClient>(() =>
        {
            var notificationUrl = Environment.GetEnvironmentVariable("NOTIFICATION_SERVICE_URL") ?? "http://notificationservice:7005";
            var channel = GrpcChannel.ForAddress(notificationUrl, new GrpcChannelOptions
            {
                Credentials = ChannelCredentials.Insecure,
                HttpHandler = new SocketsHttpHandler
                {
                    PooledConnectionIdleTimeout = Timeout.InfiniteTimeSpan,
                    KeepAlivePingDelay = TimeSpan.FromSeconds(60),
                    KeepAlivePingTimeout = TimeSpan.FromSeconds(30),
                    EnableMultipleHttp2Connections = true,
                    ConnectTimeout = TimeSpan.FromSeconds(5)
                }
            });
            return new NotificationService.NotificationServiceClient(channel);
        });

    private static NotificationService.NotificationServiceClient NotificationClient => _lazyNotificationClient.Value;

    // Polly Pipeline - Circuit Breaker + Retry + Timeout
    private static readonly Lazy<ResiliencePipeline<NotificationResponse>> _resiliencePipeline =
        new Lazy<ResiliencePipeline<NotificationResponse>>(() =>
        {
            // Configuración desde variables de ambiente
            var circuitFailureRatio = double.Parse(Environment.GetEnvironmentVariable("CIRCUIT_FAILURE_RATIO") ?? "0.5");
            var circuitSamplingDuration = int.Parse(Environment.GetEnvironmentVariable("CIRCUIT_SAMPLING_DURATION_SECONDS") ?? "30");
            var circuitBreakDuration = int.Parse(Environment.GetEnvironmentVariable("CIRCUIT_BREAK_DURATION_SECONDS") ?? "30");
            var retryMaxAttempts = int.Parse(Environment.GetEnvironmentVariable("RETRY_MAX_ATTEMPTS") ?? "2");
            var timeoutSeconds = int.Parse(Environment.GetEnvironmentVariable("TIMEOUT_SECONDS") ?? "10");

            return new ResiliencePipelineBuilder<NotificationResponse>()
                // 1. Circuit Breaker (primera línea de defensa)
                .AddCircuitBreaker(new CircuitBreakerStrategyOptions<NotificationResponse>
                {
                    FailureRatio = circuitFailureRatio,
                    SamplingDuration = TimeSpan.FromSeconds(circuitSamplingDuration),
                    MinimumThroughput = 5,
                    BreakDuration = TimeSpan.FromSeconds(circuitBreakDuration),
                    ShouldHandle = new PredicateBuilder<NotificationResponse>()
                        .Handle<RpcException>()
                        .Handle<TimeoutRejectedException>(),
                    OnOpened = args =>
                    {
                        Console.WriteLine($"🔴 [POLLY CIRCUIT] Estado: ABIERTO - Circuit breaker activado");
                        Console.WriteLine($"   Failure Ratio alcanzado: {circuitFailureRatio * 100}%");
                        Console.WriteLine($"   Duration: {circuitBreakDuration} segundos");
                        return ValueTask.CompletedTask;
                    },
                    OnClosed = args =>
                    {
                        Console.WriteLine($"🟢 [POLLY CIRCUIT] Estado: CERRADO - Circuit breaker desactivado");
                        return ValueTask.CompletedTask;
                    },
                    OnHalfOpened = args =>
                    {
                        Console.WriteLine($"🟡 [POLLY CIRCUIT] Estado: HALF-OPEN - Probando si servicio se recuperó");
                        return ValueTask.CompletedTask;
                    }
                })
                // 2. Retry (después de circuit breaker)
                .AddRetry(new RetryStrategyOptions<NotificationResponse>
                {
                    MaxRetryAttempts = retryMaxAttempts,
                    Delay = TimeSpan.FromSeconds(1),
                    BackoffType = DelayBackoffType.Exponential,
                    UseJitter = true,
                    ShouldHandle = new PredicateBuilder<NotificationResponse>()
                        .Handle<RpcException>(ex =>
                            ex.StatusCode == StatusCode.Unavailable ||
                            ex.StatusCode == StatusCode.DeadlineExceeded)
                        .Handle<TimeoutRejectedException>(),
                    OnRetry = args =>
                    {
                        var delay = args.RetryDelay.TotalSeconds;
                        Console.WriteLine($"🔄 [POLLY RETRY] Intento {args.AttemptNumber}/{retryMaxAttempts} después de {delay:F1}s");
                        if (args.Outcome.Exception != null)
                        {
                            Console.WriteLine($"   Razón: {args.Outcome.Exception.Message}");
                        }
                        return ValueTask.CompletedTask;
                    }
                })
                // 3. Timeout (límite por operación)
                .AddTimeout(new TimeoutStrategyOptions
                {
                    Timeout = TimeSpan.FromSeconds(timeoutSeconds),
                    OnTimeout = args =>
                    {
                        Console.WriteLine($"⏱️ [POLLY TIMEOUT] Operación cancelada después de {timeoutSeconds}s");
                        return ValueTask.CompletedTask;
                    }
                })
                .Build();
        });

    public async Task FunctionHandler(SQSEvent sqsEvent, ILambdaContext context)
    {
        context.Logger.LogInformation($"📧 EmailBatch Lambda iniciada - Mensajes recibidos: {sqsEvent.Records.Count}");

        // Log de configuración Polly
        var circuitFailureRatio = Environment.GetEnvironmentVariable("CIRCUIT_FAILURE_RATIO") ?? "0.5";
        var circuitBreakDuration = Environment.GetEnvironmentVariable("CIRCUIT_BREAK_DURATION_SECONDS") ?? "30";
        var retryMaxAttempts = Environment.GetEnvironmentVariable("RETRY_MAX_ATTEMPTS") ?? "2";

        context.Logger.LogInformation($"⚙️ [POLLY CONFIG] Circuit Breaker: {circuitFailureRatio} ratio, {circuitBreakDuration}s break");
        context.Logger.LogInformation($"⚙️ [POLLY CONFIG] Retry: {retryMaxAttempts} intentos");

        var pipeline = _resiliencePipeline.Value;
        var successCount = 0;
        var failureCount = 0;
        var circuitOpenCount = 0;

        foreach (var record in sqsEvent.Records)
        {
            try
            {
                context.Logger.LogInformation($"\n📬 Procesando mensaje {record.MessageId}");

                // Deserializar mensaje
                var emailRequest = JsonSerializer.Deserialize<EmailNotificationRequest>(record.Body);

                if (emailRequest == null)
                {
                    context.Logger.LogError("❌ Error: Mensaje inválido (deserialización falló)");
                    failureCount++;
                    continue;
                }

                context.Logger.LogInformation($"   Para: {emailRequest.EmailTo}");
                context.Logger.LogInformation($"   Asunto: {emailRequest.Subject}");

                // Enviar email con resiliencia
                var response = await SendEmailWithResilience(emailRequest, pipeline, context);

                if (response.Status == "Sent")
                {
                    successCount++;
                    context.Logger.LogInformation($"✅ Email enviado exitosamente a {emailRequest.EmailTo}");
                }
                else if (response.Status == "CircuitOpen")
                {
                    // Circuit está abierto - mensaje debe ir a DLQ
                    circuitOpenCount++;
                    context.Logger.LogWarning($"⚡ [POLLY CIRCUIT] Circuit ABIERTO - Mensaje redirigido a DLQ");
                    throw new Exception("Circuit breaker abierto - mensaje redirigido a DLQ");
                }
                else
                {
                    failureCount++;
                    context.Logger.LogWarning($"⚠️ Email falló: {response.FailureReason}");
                }
            }
            catch (RpcException ex) when (ex.StatusCode == StatusCode.Unavailable)
            {
                // Servicio no disponible - después de reintentos
                failureCount++;
                context.Logger.LogError($"❌ [gRPC ERROR] NotificationService no disponible: {ex.Status.Detail}");
                context.Logger.LogError($"   Todos los reintentos fallaron");
                context.Logger.LogError($"   Mensaje será enviado a DLQ");

                // Relanzar para que SQS marque como fallido
                throw;
            }
            catch (TimeoutRejectedException ex)
            {
                // Timeout después de reintentos
                failureCount++;
                context.Logger.LogError($"⏱️ [TIMEOUT] Timeout después de reintentos: {ex.Message}");
                context.Logger.LogError($"   Mensaje será enviado a DLQ");

                // Relanzar para que SQS marque como fallido
                throw;
            }
            catch (Exception ex)
            {
                // Cualquier otra excepción
                failureCount++;
                context.Logger.LogError($"❌ Error inesperado: {ex.GetType().Name}");
                context.Logger.LogError($"   Mensaje: {ex.Message}");

                // Relanzar para que SQS marque como fallido
                throw;
            }
        }

        // Resumen
        context.Logger.LogInformation($"\n📊 Resumen de procesamiento:");
        context.Logger.LogInformation($"   ✅ Exitosos: {successCount}");
        context.Logger.LogInformation($"   ❌ Fallidos: {failureCount}");
        context.Logger.LogInformation($"   ⚡ Circuit abierto: {circuitOpenCount}");
        context.Logger.LogInformation($"   📧 Total: {sqsEvent.Records.Count}");

        if (failureCount > 0 || circuitOpenCount > 0)
        {
            context.Logger.LogWarning($"⚠️ Lambda completada con {failureCount + circuitOpenCount} fallas");
        }
        else
        {
            context.Logger.LogInformation($"🎉 Todos los mensajes procesados exitosamente");
        }
    }

    private async Task<NotificationResponse> SendEmailWithResilience(
        EmailNotificationRequest emailRequest,
        ResiliencePipeline<NotificationResponse> pipeline,
        ILambdaContext context)
    {
        try
        {
            // Ejecutar con Polly pipeline (Circuit Breaker + Retry + Timeout)
            return await pipeline.ExecuteAsync(async ct =>
            {
                // Llamada gRPC al NotificationService
                var grpcRequest = new SendEmailRequest
                {
                    UserId = emailRequest.UserId,
                    OrderId = emailRequest.OrderId,
                    EmailTo = emailRequest.EmailTo,
                    Subject = emailRequest.Subject,
                    Body = emailRequest.Body,
                    Template = emailRequest.Template ?? "Default"
                };

                return await NotificationClient.SendEmailAsync(grpcRequest, cancellationToken: ct);
            }, CancellationToken.None);
        }
        catch (BrokenCircuitException)
        {
            // Circuit está abierto - retornar respuesta especial
            context.Logger.LogWarning("[POLLY] Circuit abierto - no se puede procesar");
            return new NotificationResponse
            {
                NotificationId = 0,
                UserId = emailRequest.UserId,
                OrderId = emailRequest.OrderId,
                NotificationType = "Email",
                Recipient = emailRequest.EmailTo,
                Subject = emailRequest.Subject,
                Message = emailRequest.Body,
                Template = emailRequest.Template,
                Status = "CircuitOpen",
                FailureReason = "Circuit breaker is open - service unavailable",
                CreatedAt = DateTime.UtcNow.ToString("o")
            };
        }
    }
}

// DTOs
public class EmailNotificationRequest
{
    public int UserId { get; set; }
    public int OrderId { get; set; }
    public string EmailTo { get; set; } = string.Empty;
    public string Subject { get; set; } = string.Empty;
    public string Body { get; set; } = string.Empty;
    public string Template { get; set; } = string.Empty;
}