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

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace EmailBatch.Lambda
{
    public class Function
    {
        private GrpcChannel _channel;
        private NotificationService.NotificationServiceClient _client;
        private readonly string _notificationServiceUrl;

        public Function()
        {
            // ✅ SOLO guardar la URL, NO crear el canal aún
            _notificationServiceUrl = Environment.GetEnvironmentVariable("NOTIFICATION_SERVICE_URL")
                ?? "http://notificationservice:7005";

            Console.WriteLine($"EmailBatch Lambda inicializada. Service URL: {_notificationServiceUrl}");
        }

        // ✅ Crear conexión bajo demanda (lazy initialization)
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
                    ConnectTimeout = TimeSpan.FromSeconds(5)  // ✅ Timeout de conexión
                }
            });

            _client = new NotificationService.NotificationServiceClient(_channel);
        }

        public async Task FunctionHandler(SQSEvent sqsEvent, ILambdaContext context)
        {
            context.Logger.LogInformation($"=== INICIANDO PROCESAMIENTO ===");
            context.Logger.LogInformation($"Mensajes recibidos: {sqsEvent.Records.Count}");
            context.Logger.LogInformation($"NotificationService URL: {_notificationServiceUrl}");

            // ✅ Crear cliente gRPC AQUÍ (primera vez que se usa)
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

            var processedCount = 0;
            var failedCount = 0;

            foreach (var record in sqsEvent.Records)
            {
                try
                {
                    context.Logger.LogInformation($"Procesando mensaje {record.MessageId}");

                    var emailRequest = JsonSerializer.Deserialize<EmailNotificationRequest>(record.Body);
                    context.Logger.LogInformation($"Destino: {emailRequest.EmailTo}, Asunto: {emailRequest.Subject}");

                    var request = new SendEmailRequest
                    {
                        UserId = emailRequest.UserId,
                        OrderId = emailRequest.OrderId,
                        EmailTo = emailRequest.EmailTo,
                        Subject = emailRequest.Subject,
                        Body = emailRequest.Body,
                        Template = emailRequest.Template ?? "Default"
                    };

                    // ✅ Timeout en la llamada gRPC
                    var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));

                    context.Logger.LogInformation($"Enviando request gRPC a NotificationService...");
                    var response = await _client.SendEmailAsync(request, cancellationToken: cts.Token);
                    context.Logger.LogInformation($"Respuesta recibida. Status: {response.Status}");

                    if (response.Status != "Sent")
                    {
                        var errorMsg = response.Status == "Failed"
                            ? $"Email falló: {response.FailureReason}"
                            : $"Email en estado inesperado: {response.Status}";

                        context.Logger.LogWarning(errorMsg);
                        failedCount++;
                    }
                    else
                    {
                        context.Logger.LogInformation($"✓ Email enviado exitosamente a {emailRequest.EmailTo}");
                        processedCount++;
                    }
                }
                catch (RpcException rpcEx)
                {
                    context.Logger.LogError($"✗ Error gRPC: {rpcEx.Status.StatusCode} - {rpcEx.Status.Detail}");
                    context.Logger.LogError($"Debug Info: {rpcEx.Message}");
                    failedCount++;
                    throw; // Re-throw para SQS retry/DLQ
                }
                catch (Exception ex)
                {
                    context.Logger.LogError($"✗ Error procesando mensaje: {ex.Message}");
                    context.Logger.LogError($"Stack trace: {ex.StackTrace}");
                    failedCount++;
                    throw; // Re-throw para SQS retry/DLQ
                }
            }

            context.Logger.LogInformation($"=== PROCESAMIENTO COMPLETADO ===");
            context.Logger.LogInformation($"Exitosos: {processedCount}, Fallidos: {failedCount}");
        }

        // ✅ Cleanup al destruir (opcional pero buena práctica)
        public void Dispose()
        {
            _channel?.Dispose();
        }
    }

    public class EmailNotificationRequest
    {
        public int UserId { get; set; }
        public int OrderId { get; set; }
        public string EmailTo { get; set; }
        public string Subject { get; set; }
        public string Body { get; set; }
        public string Template { get; set; }
    }
}