using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Amazon.Lambda.Core;
using Amazon.Lambda.SQSEvents;
using ECommerceGRPC.NotificationService;
using Grpc.Core;
using Grpc.Net.Client;
using Polly;
using Polly.CircuitBreaker;
using Polly.Retry;
using Polly.Timeout;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace EmailBatch.Lambda
{
    /// <summary>
    /// Lambda function para procesar emails en batch CON RESILIENCIA (Polly).
    /// 
    /// SEMANA 2 - CAMBIOS CON POLLY:
    /// ✅ Circuit Breaker: Abre después de 50% de fallas en 30 segundos
    /// ✅ Retry Policy: 2 intentos con backoff exponencial
    /// ✅ Timeout Policy: 10 segundos máximo por llamada gRPC
    /// 
    /// Flujo:
    /// 1. Recibe batch de mensajes desde SQS
    /// 2. Por cada mensaje, envía email vía NotificationService.gRPC
    /// 3. Circuit Breaker protege contra sobrecarga del servicio
    /// 4. Si circuit abre, mensajes van a DLQ para reprocesar después
    /// 
    /// Integración: NotificationService.gRPC (puerto 7005)
    /// Event Source: SQS (email-notifications-queue)
    /// DLQ: email-notifications-dlq
    /// </summary>
    public class Function : IDisposable
    {
        private GrpcChannel? _channel;
        private NotificationService.NotificationServiceClient? _client;
        private readonly string _notificationServiceUrl;

        // ✅ SEMANA 2: Pipeline de resiliencia Polly (singleton para reutilizar)
        private static ResiliencePipeline<NotificationResponse>? _resiliencePipeline;

        public Function()
        {
            // ✅ SOLO guardar la URL, NO crear el canal aún (lazy initialization)
            _notificationServiceUrl = Environment.GetEnvironmentVariable("NOTIFICATION_SERVICE_URL")
                ?? "http://notificationservice:7005";

            Console.WriteLine($"EmailBatch Lambda inicializada. Service URL: {_notificationServiceUrl}");
        }

        /// <summary>
        /// ✅ SEMANA 1: Crear conexión bajo demanda (lazy initialization)
        /// </summary>
        private void EnsureGrpcClient()
        {
            if (_client != null)
                return;

            _channel = GrpcChannel.ForAddress(_notificationServiceUrl, new GrpcChannelOptions
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

            _client = new NotificationService.NotificationServiceClient(_channel);
        }

        /// <summary>
        /// ✅ SEMANA 2: Configurar pipeline de resiliencia Polly
        /// Pipeline: Timeout → Circuit Breaker → Retry → gRPC Call
        /// </summary>
        private ResiliencePipeline<NotificationResponse> GetOrCreateResiliencePipeline(ILambdaContext context)
        {
            if (_resiliencePipeline != null)
                return _resiliencePipeline;

            // Leer configuración desde variables de ambiente (con defaults)
            var circuitFailureRatio = double.Parse(Environment.GetEnvironmentVariable("CIRCUIT_FAILURE_RATIO") ?? "0.5");
            var circuitSamplingDuration = int.Parse(Environment.GetEnvironmentVariable("CIRCUIT_SAMPLING_DURATION_SECONDS") ?? "30");
            var circuitBreakDuration = int.Parse(Environment.GetEnvironmentVariable("CIRCUIT_BREAK_DURATION_SECONDS") ?? "30");
            var retryMaxAttempts = int.Parse(Environment.GetEnvironmentVariable("RETRY_MAX_ATTEMPTS") ?? "2");
            var timeoutSeconds = int.Parse(Environment.GetEnvironmentVariable("TIMEOUT_SECONDS") ?? "10");

            context.Logger.LogInformation($"[POLLY CONFIG] CircuitFailureRatio={circuitFailureRatio}, " +
                $"SamplingDuration={circuitSamplingDuration}s, BreakDuration={circuitBreakDuration}s, " +
                $"MaxRetries={retryMaxAttempts}, Timeout={timeoutSeconds}s");

            var pipelineBuilder = new ResiliencePipelineBuilder<NotificationResponse>();

            // 1️⃣ TIMEOUT POLICY (capa externa - máximo tiempo absoluto)
            pipelineBuilder.AddTimeout(new TimeoutStrategyOptions
            {
                Timeout = TimeSpan.FromSeconds(timeoutSeconds),
                OnTimeout = args =>
                {
                    context.Logger.LogError($"[POLLY TIMEOUT] Operación excedió {timeoutSeconds}s");
                    return ValueTask.CompletedTask;
                }
            });

            // 2️⃣ CIRCUIT BREAKER POLICY
            pipelineBuilder.AddCircuitBreaker(new CircuitBreakerStrategyOptions<NotificationResponse>
            {
                FailureRatio = circuitFailureRatio,
                SamplingDuration = TimeSpan.FromSeconds(circuitSamplingDuration),
                MinimumThroughput = 5,  // Mínimo 5 requests antes de evaluar
                BreakDuration = TimeSpan.FromSeconds(circuitBreakDuration),
                ShouldHandle = new PredicateBuilder<NotificationResponse>()
                    .Handle<RpcException>()
                    .Handle<TimeoutException>()
                    .Handle<HttpRequestException>()
                    .HandleResult(response => response.Status == "Failed"),
                OnOpened = args =>
                {
                    context.Logger.LogError("[POLLY CIRCUIT] ⚠️ CIRCUIT ABIERTO - Rechazando requests por sobrecarga");
                    context.Logger.LogError($"[POLLY CIRCUIT] Motivo: {args.Outcome.Exception?.Message ?? args.Outcome.Result?.FailureReason ?? "Unknown"}");
                    return ValueTask.CompletedTask;
                },
                OnClosed = args =>
                {
                    context.Logger.LogInformation("[POLLY CIRCUIT] ✅ CIRCUIT CERRADO - Servicio recuperado");
                    return ValueTask.CompletedTask;
                },
                OnHalfOpened = args =>
                {
                    context.Logger.LogInformation("[POLLY CIRCUIT] 🔄 CIRCUIT HALF-OPEN - Probando servicio...");
                    return ValueTask.CompletedTask;
                }
            });

            // 3️⃣ RETRY POLICY (menos intentos que ImageProcessor porque tenemos Circuit Breaker)
            pipelineBuilder.AddRetry(new RetryStrategyOptions<NotificationResponse>
            {
                MaxRetryAttempts = retryMaxAttempts,
                Delay = TimeSpan.FromSeconds(1),
                BackoffType = DelayBackoffType.Exponential,
                UseJitter = true,
                ShouldHandle = new PredicateBuilder<NotificationResponse>()
                    .Handle<RpcException>()
                    .Handle<TimeoutException>()
                    .Handle<HttpRequestException>()
                    .HandleResult(response => response.Status == "Failed"),
                OnRetry = args =>
                {
                    var attemptNumber = args.AttemptNumber + 1;
                    var delay = args.RetryDelay.TotalSeconds;
                    context.Logger.LogWarning($"[POLLY RETRY] Intento {attemptNumber}/{retryMaxAttempts} después de {delay:F1}s");

                    if (args.Outcome.Exception != null)
                    {
                        context.Logger.LogWarning($"[POLLY RETRY] Excepción: {args.Outcome.Exception.Message}");
                    }
                    else if (args.Outcome.Result != null)
                    {
                        context.Logger.LogWarning($"[POLLY RETRY] Email falló: {args.Outcome.Result.FailureReason}");
                    }

                    return ValueTask.CompletedTask;
                }
            });

            _resiliencePipeline = pipelineBuilder.Build();
            context.Logger.LogInformation("[POLLY] Pipeline de resiliencia configurado exitosamente");

            return _resiliencePipeline;
        }

        public async Task FunctionHandler(SQSEvent sqsEvent, ILambdaContext context)
        {
            context.Logger.LogInformation("===========================================");
            context.Logger.LogInformation($"📧 EmailBatch Lambda (SEMANA 2 con Polly)");
            context.Logger.LogInformation($"📬 Procesando {sqsEvent.Records.Count} mensaje(s)");
            context.Logger.LogInformation($"🔗 NotificationService URL: {_notificationServiceUrl}");
            context.Logger.LogInformation("===========================================");

            // ✅ SEMANA 1: Crear cliente gRPC AQUÍ (lazy initialization)
            try
            {
                EnsureGrpcClient();
                context.Logger.LogInformation("✓ Cliente gRPC inicializado");
            }
            catch (Exception ex)
            {
                context.Logger.LogError($"✗ Error inicializando cliente gRPC: {ex.Message}");
                throw;
            }

            // ✅ SEMANA 2: Obtener pipeline de resiliencia
            var pipeline = GetOrCreateResiliencePipeline(context);

            var processedCount = 0;
            var failedCount = 0;
            var circuitOpenCount = 0;

            foreach (var record in sqsEvent.Records)
            {
                try
                {
                    context.Logger.LogInformation($"\n--- Procesando mensaje {record.MessageId} ---");

                    var emailRequest = JsonSerializer.Deserialize<EmailNotificationRequest>(record.Body);
                    context.Logger.LogInformation($"📧 Destino: {emailRequest.EmailTo}, Asunto: {emailRequest.Subject}");

                    // ✅ SEMANA 2: Enviar email con Polly pipeline
                    var response = await SendEmailWithResilience(emailRequest, pipeline, context);

                    if (response.Status == "Sent")
                    {
                        context.Logger.LogInformation($"✅ Email enviado exitosamente");
                        processedCount++;
                    }
                    else if (response.Status == "CircuitOpen")
                    {
                        // Circuit está abierto - mensaje irá a DLQ para reprocesar después
                        context.Logger.LogWarning($"⚠️ Circuit abierto - Mensaje enviado a DLQ");
                        circuitOpenCount++;
                        throw new Exception("Circuit breaker abierto - mensaje redirigido a DLQ");
                    }
                    else
                    {
                        context.Logger.LogWarning($"⚠️ Email falló: {response.FailureReason}");
                        failedCount++;
                    }
                }
                catch (BrokenCircuitException)
                {
                    // Circuit abierto - mensaje va a DLQ
                    context.Logger.LogError($"❌ Circuit ABIERTO - Mensaje redirigido a DLQ");
                    circuitOpenCount++;
                    throw; // Re-throw para que SQS envíe a DLQ
                }
                catch (RpcException rpcEx)
                {
                    context.Logger.LogError($"❌ Error gRPC: {rpcEx.Status.StatusCode} - {rpcEx.Status.Detail}");
                    failedCount++;
                    throw; // Re-throw para SQS retry/DLQ
                }
                catch (Exception ex)
                {
                    context.Logger.LogError($"❌ Error procesando mensaje: {ex.Message}");
                    failedCount++;
                    throw; // Re-throw para SQS retry/DLQ
                }
            }

            context.Logger.LogInformation("\n===========================================");
            context.Logger.LogInformation($"📊 Resumen:");
            context.Logger.LogInformation($"  ✅ Exitosos: {processedCount}");
            context.Logger.LogInformation($"  ❌ Fallidos: {failedCount}");
            context.Logger.LogInformation($"  ⚠️ Circuit abierto: {circuitOpenCount}");
            context.Logger.LogInformation("===========================================");
        }

        /// <summary>
        /// ✅ SEMANA 2: Enviar email con Polly pipeline
        /// Pipeline: Timeout → Circuit Breaker → Retry → gRPC Call
        /// </summary>
        private async Task<NotificationResponse> SendEmailWithResilience(
            EmailNotificationRequest emailRequest,
            ResiliencePipeline<NotificationResponse> pipeline,
            ILambdaContext context)
        {
            try
            {
                context.Logger.LogInformation("[POLLY] Ejecutando llamada gRPC con resiliencia...");

                var request = new SendEmailRequest
                {
                    UserId = emailRequest.UserId,
                    OrderId = emailRequest.OrderId,
                    EmailTo = emailRequest.EmailTo,
                    Subject = emailRequest.Subject,
                    Body = emailRequest.Body,
                    Template = emailRequest.Template ?? "Default"
                };

                // Ejecutar con pipeline de resiliencia
                var response = await pipeline.ExecuteAsync(async ct =>
                {
                    context.Logger.LogInformation($"  → Enviando email vía gRPC...");
                    return await _client!.SendEmailAsync(request, cancellationToken: ct);
                }, CancellationToken.None);  // ✅ CORREGIDO: usar CancellationToken.None

                context.Logger.LogInformation($"[POLLY] Respuesta recibida. Status: {response.Status}");

                return response;
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
            catch (Exception ex)
            {
                // Otros errores no manejados
                context.Logger.LogError($"[POLLY] ❌ Error no manejado: {ex.Message}");
                throw;
            }
        }

        /// <summary>
        /// ✅ SEMANA 1: Cleanup al destruir (opcional pero buena práctica)
        /// </summary>
        public void Dispose()
        {
            _channel?.Dispose();
        }
    }

    /// <summary>
    /// Modelo de request de email desde SQS
    /// </summary>
    public class EmailNotificationRequest
    {
        public int UserId { get; set; }
        public int OrderId { get; set; }
        public string EmailTo { get; set; } = string.Empty;
        public string Subject { get; set; } = string.Empty;
        public string Body { get; set; } = string.Empty;
        public string Template { get; set; } = string.Empty;
    }
}