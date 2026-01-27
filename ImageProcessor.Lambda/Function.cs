using Amazon.Lambda.Core;
using Amazon.Lambda.S3Events;
using Amazon.S3;
using Amazon.S3.Model;
using Grpc.Net.Client;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Processing;
using SixLabors.ImageSharp.Formats.Jpeg;
using System.Text.Json;
using ECommerceGRPC.ProductService;
using Polly;
using Polly.Retry;
using Polly.Timeout;
using Polly.Fallback;
using Grpc.Core;

// Assembly attribute para especificar el serializador JSON de Lambda
[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace ImageProcessor.Lambda
{
    /// <summary>
    /// Lambda function para procesar imágenes de productos CON RESILIENCIA (Polly).
    /// 
    /// SEMANA 2 - CAMBIOS CON POLLY:
    /// ✅ Retry Policy: 3 intentos con backoff exponencial
    /// ✅ Timeout Policy: 10 segundos máximo por llamada gRPC
    /// ✅ Fallback Policy: Si ProductService falla, continuar con siguiente imagen
    /// 
    /// Flujo:
    /// 1. Se dispara cuando se sube una imagen a S3
    /// 2. Genera thumbnails (200x200, 400x400)
    /// 3. Optimiza la imagen original
    /// 4. Actualiza ProductService vía gRPC con RESILIENCIA
    /// 
    /// Integración: ProductService.gRPC (puerto 7001)
    /// Event Source: S3 (bucket: product-images)
    /// Output: S3 (bucket: product-images-processed)
    /// </summary>
    public class Function
    {
        private readonly IAmazonS3 _s3Client;
        private readonly GrpcChannel _grpcChannel;
        private readonly string _productServiceUrl;
        private readonly string _outputBucket;

        // ✅ SEMANA 2: Pipeline de resiliencia Polly (singleton para reutilizar)
        private static ResiliencePipeline<ProductResponse>? _resiliencePipeline;

        /// <summary>
        /// Constructor por defecto - usado por Lambda runtime
        /// </summary>
        public Function()
        {
            // Configuración de S3 para LocalStack
            var s3Config = new AmazonS3Config
            {
                ServiceURL = Environment.GetEnvironmentVariable("S3_ENDPOINT") ?? "http://localhost:4566",
                ForcePathStyle = true
            };
            _s3Client = new AmazonS3Client(s3Config);

            // Configuración del cliente gRPC a ProductService
            _productServiceUrl = Environment.GetEnvironmentVariable("PRODUCT_SERVICE_URL") ?? "http://productservice:7001";
            _grpcChannel = GrpcChannel.ForAddress(_productServiceUrl);

            // Bucket de salida para imágenes procesadas
            _outputBucket = Environment.GetEnvironmentVariable("OUTPUT_BUCKET") ?? "product-images-processed";
        }

        /// <summary>
        /// Constructor para testing - permite inyectar dependencias
        /// </summary>
        public Function(IAmazonS3 s3Client, GrpcChannel grpcChannel, string outputBucket)
        {
            _s3Client = s3Client;
            _grpcChannel = grpcChannel;
            _outputBucket = outputBucket;
            _productServiceUrl = grpcChannel.Target;
        }

        /// <summary>
        /// ✅ SEMANA 2: Configurar pipeline de resiliencia Polly
        /// Pipeline: Timeout → Retry → Fallback → gRPC Call
        /// </summary>
        private ResiliencePipeline<ProductResponse> GetOrCreateResiliencePipeline(ILambdaContext context)
        {
            if (_resiliencePipeline != null)
                return _resiliencePipeline;

            // Leer configuración desde variables de ambiente (con defaults)
            var maxRetryAttempts = int.Parse(Environment.GetEnvironmentVariable("RETRY_MAX_ATTEMPTS") ?? "3");
            var retryDelaySeconds = int.Parse(Environment.GetEnvironmentVariable("RETRY_DELAY_SECONDS") ?? "1");
            var timeoutSeconds = int.Parse(Environment.GetEnvironmentVariable("TIMEOUT_SECONDS") ?? "10");
            var fallbackEnabled = bool.Parse(Environment.GetEnvironmentVariable("FALLBACK_ENABLED") ?? "true");

            context.Logger.LogInformation($"[POLLY CONFIG] MaxRetries={maxRetryAttempts}, Delay={retryDelaySeconds}s, Timeout={timeoutSeconds}s");

            var pipelineBuilder = new ResiliencePipelineBuilder<ProductResponse>();

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

            // 2️⃣ RETRY POLICY (backoff exponencial con jitter)
            pipelineBuilder.AddRetry(new RetryStrategyOptions<ProductResponse>
            {
                MaxRetryAttempts = maxRetryAttempts,
                Delay = TimeSpan.FromSeconds(retryDelaySeconds),
                BackoffType = DelayBackoffType.Exponential,
                UseJitter = true,
                ShouldHandle = new PredicateBuilder<ProductResponse>()
                    .Handle<RpcException>()
                    .Handle<TimeoutException>()
                    .Handle<HttpRequestException>(),
                OnRetry = args =>
                {
                    var attemptNumber = args.AttemptNumber + 1;
                    var delay = args.RetryDelay.TotalSeconds;
                    context.Logger.LogWarning($"[POLLY RETRY] Intento {attemptNumber}/{maxRetryAttempts} después de {delay:F1}s");

                    if (args.Outcome.Exception != null)
                    {
                        context.Logger.LogWarning($"[POLLY RETRY] Excepción: {args.Outcome.Exception.Message}");
                    }

                    return ValueTask.CompletedTask;
                }
            });

            // 3️⃣ FALLBACK POLICY (si todos los reintentos fallan)
            if (fallbackEnabled)
            {
                pipelineBuilder.AddFallback(new FallbackStrategyOptions<ProductResponse>
                {
                    ShouldHandle = new PredicateBuilder<ProductResponse>()
                        .Handle<RpcException>()
                        .Handle<TimeoutException>()
                        .Handle<HttpRequestException>(),
                    FallbackAction = args =>
                    {
                        context.Logger.LogWarning("[POLLY FALLBACK] Todos los reintentos fallaron - activando fallback");
                        context.Logger.LogWarning($"[POLLY FALLBACK] Excepción final: {args.Outcome.Exception?.Message}");

                        // Retornar respuesta default para permitir continuar con siguiente imagen
                        return Outcome.FromResultAsValueTask(new ProductResponse
                        {
                            Id = 0,
                            Name = "Fallback",
                            Description = "Service unavailable",
                            Price = 0,
                            Stock = 0,
                            Category = "Error",
                            IsActive = false,
                            CreatedAt = DateTime.UtcNow.ToString("o"),
                            UpdatedAt = DateTime.UtcNow.ToString("o")
                        });
                    }
                });
            }

            _resiliencePipeline = pipelineBuilder.Build();
            context.Logger.LogInformation("[POLLY] Pipeline de resiliencia configurado exitosamente");

            return _resiliencePipeline;
        }

        /// <summary>
        /// Handler principal de la función Lambda
        /// Procesa eventos de S3 cuando se suben imágenes de productos
        /// </summary>
        public async Task<string> FunctionHandler(S3Event s3Event, ILambdaContext context)
        {
            var processedCount = 0;
            var errors = new List<string>();

            context.Logger.LogInformation("===========================================");
            context.Logger.LogInformation($"🎨 ImageProcessor Lambda (SEMANA 2 con Polly)");
            context.Logger.LogInformation($"📸 Procesando {s3Event.Records.Count} eventos de S3");
            context.Logger.LogInformation("===========================================");

            foreach (var record in s3Event.Records)
            {
                try
                {
                    var bucketName = record.S3.Bucket.Name;
                    var objectKey = record.S3.Object.Key;

                    context.Logger.LogInformation($"\n--- Procesando imagen: {bucketName}/{objectKey} ---");

                    // Validar que sea una imagen
                    if (!IsValidImageFile(objectKey))
                    {
                        context.Logger.LogWarning($"⚠️ Archivo ignorado (no es imagen): {objectKey}");
                        continue;
                    }

                    // Extraer ProductId del nombre del archivo
                    // Formato esperado: products/{productId}/original.jpg
                    var productId = ExtractProductIdFromKey(objectKey);
                    if (productId == 0)
                    {
                        context.Logger.LogWarning($"⚠️ No se pudo extraer ProductId de: {objectKey}");
                        continue;
                    }

                    context.Logger.LogInformation($"📦 ProductId extraído: {productId}");

                    // 1. Descargar imagen original de S3
                    context.Logger.LogInformation("1️⃣ Descargando imagen original...");
                    using var originalImage = await DownloadImageFromS3(bucketName, objectKey, context);

                    // 2. Procesar imagen (generar thumbnails y optimizar)
                    context.Logger.LogInformation("2️⃣ Procesando imagen (thumbnails + optimización)...");
                    var processedImages = await ProcessImage(originalImage, context);

                    // 3. Subir imágenes procesadas a S3
                    context.Logger.LogInformation("3️⃣ Subiendo imágenes procesadas a S3...");
                    var imageUrls = await UploadProcessedImages(productId, processedImages, context);

                    // 4. Actualizar ProductService vía gRPC CON POLLY
                    context.Logger.LogInformation("4️⃣ Actualizando ProductService vía gRPC (CON POLLY)...");
                    var updateSuccess = await UpdateProductImagesWithResilience(productId, imageUrls, context);

                    if (updateSuccess)
                    {
                        processedCount++;
                        context.Logger.LogInformation($"✅ Imagen procesada exitosamente: ProductId={productId}");
                    }
                    else
                    {
                        context.Logger.LogWarning($"⚠️ Imagen procesada pero ProductService no actualizado: ProductId={productId}");
                        processedCount++; // Aún cuenta como éxito parcial
                    }
                }
                catch (Exception ex)
                {
                    var errorMsg = $"Error procesando imagen: {ex.Message}";
                    context.Logger.LogError($"❌ {errorMsg}");
                    context.Logger.LogError($"Stack trace: {ex.StackTrace}");
                    errors.Add(errorMsg);
                }
            }

            context.Logger.LogInformation("\n===========================================");
            context.Logger.LogInformation($"📊 Resumen: {processedCount}/{s3Event.Records.Count} procesadas exitosamente");
            if (errors.Any())
            {
                context.Logger.LogError($"❌ Errores: {errors.Count}");
                foreach (var error in errors)
                {
                    context.Logger.LogError($"  - {error}");
                }
            }
            context.Logger.LogInformation("===========================================");

            return $"Procesadas: {processedCount}/{s3Event.Records.Count}";
        }

        /// <summary>
        /// Valida si el archivo es una imagen soportada
        /// </summary>
        private bool IsValidImageFile(string key)
        {
            var validExtensions = new[] { ".jpg", ".jpeg", ".png", ".gif", ".webp" };
            var extension = Path.GetExtension(key).ToLowerInvariant();
            return validExtensions.Contains(extension);
        }

        /// <summary>
        /// Extrae ProductId del key de S3
        /// Formato esperado: products/{productId}/original.jpg
        /// </summary>
        private int ExtractProductIdFromKey(string key)
        {
            try
            {
                var parts = key.Split('/');
                if (parts.Length >= 2 && parts[0] == "products")
                {
                    return int.Parse(parts[1]);
                }
            }
            catch
            {
                // Log ya se maneja en el caller
            }
            return 0;
        }

        /// <summary>
        /// Descarga imagen desde S3
        /// </summary>
        private async Task<Image> DownloadImageFromS3(string bucketName, string key, ILambdaContext context)
        {
            var request = new GetObjectRequest
            {
                BucketName = bucketName,
                Key = key
            };

            using var response = await _s3Client.GetObjectAsync(request);
            using var responseStream = response.ResponseStream;

            context.Logger.LogInformation($"  ✓ Imagen descargada: {response.ContentLength} bytes");

            return await Image.LoadAsync(responseStream);
        }

        /// <summary>
        /// Procesa imagen: genera thumbnails (200x200, 400x400) y optimiza original
        /// </summary>
        private async Task<Dictionary<string, MemoryStream>> ProcessImage(Image originalImage, ILambdaContext context)
        {
            var processedImages = new Dictionary<string, MemoryStream>();

            // 1. Thumbnail 200x200
            context.Logger.LogInformation("  📐 Generando thumbnail 200x200...");
            var thumbnail200 = originalImage.Clone(img => img.Resize(new ResizeOptions
            {
                Size = new Size(200, 200),
                Mode = ResizeMode.Max
            }));

            var stream200 = new MemoryStream();
            await thumbnail200.SaveAsync(stream200, new JpegEncoder { Quality = 85 });
            stream200.Position = 0;
            processedImages["thumbnail_200"] = stream200;
            context.Logger.LogInformation($"    ✓ Thumbnail 200x200: {stream200.Length} bytes");

            // 2. Thumbnail 400x400
            context.Logger.LogInformation("  📐 Generando thumbnail 400x400...");
            var thumbnail400 = originalImage.Clone(img => img.Resize(new ResizeOptions
            {
                Size = new Size(400, 400),
                Mode = ResizeMode.Max
            }));

            var stream400 = new MemoryStream();
            await thumbnail400.SaveAsync(stream400, new JpegEncoder { Quality = 85 });
            stream400.Position = 0;
            processedImages["thumbnail_400"] = stream400;
            context.Logger.LogInformation($"    ✓ Thumbnail 400x400: {stream400.Length} bytes");

            // 3. Imagen optimizada (máximo 1200x1200)
            context.Logger.LogInformation("  ⚙️ Optimizando imagen original...");
            var optimized = originalImage.Clone(img => img.Resize(new ResizeOptions
            {
                Size = new Size(1200, 1200),
                Mode = ResizeMode.Max
            }));

            var streamOptimized = new MemoryStream();
            await optimized.SaveAsync(streamOptimized, new JpegEncoder { Quality = 90 });
            streamOptimized.Position = 0;
            processedImages["optimized"] = streamOptimized;
            context.Logger.LogInformation($"    ✓ Optimizada: {streamOptimized.Length} bytes");

            context.Logger.LogInformation($"  ✅ {processedImages.Count} imágenes procesadas");

            return processedImages;
        }

        /// <summary>
        /// Sube imágenes procesadas a S3
        /// </summary>
        private async Task<Dictionary<string, string>> UploadProcessedImages(
            int productId,
            Dictionary<string, MemoryStream> processedImages,
            ILambdaContext context)
        {
            var urls = new Dictionary<string, string>();

            foreach (var kvp in processedImages)
            {
                var imageType = kvp.Key;
                var imageStream = kvp.Value;

                // Formato: products/{productId}/{imageType}.jpg
                var key = $"products/{productId}/{imageType}.jpg";

                var putRequest = new PutObjectRequest
                {
                    BucketName = _outputBucket,
                    Key = key,
                    InputStream = imageStream,
                    ContentType = "image/jpeg"
                };

                await _s3Client.PutObjectAsync(putRequest);

                // Generar URL (en LocalStack)
                var url = $"http://localhost:4566/{_outputBucket}/{key}";
                urls[imageType] = url;

                context.Logger.LogInformation($"  ✓ Subida: {key}");
            }

            context.Logger.LogInformation($"  ✅ {urls.Count} imágenes subidas a S3");

            return urls;
        }

        /// <summary>
        /// ✅ SEMANA 2: Actualiza ProductService vía gRPC CON POLLY RESILIENCE
        /// Pipeline: Timeout → Retry → Fallback → gRPC Call
        /// </summary>
        private async Task<bool> UpdateProductImagesWithResilience(
            int productId,
            Dictionary<string, string> imageUrls,
            ILambdaContext context)
        {
            try
            {
                var client = new ProductService.ProductServiceClient(_grpcChannel);

                // Obtener pipeline de resiliencia
                var pipeline = GetOrCreateResiliencePipeline(context);

                context.Logger.LogInformation("[POLLY] Ejecutando llamada gRPC con resiliencia...");

                // Ejecutar llamada gRPC con Polly pipeline
                var response = await pipeline.ExecuteAsync(async ct =>
                {
                    // 1. Obtener producto actual
                    context.Logger.LogInformation($"  → Obteniendo producto {productId}...");
                    var getRequest = new GetProductRequest { Id = productId };
                    var product = await client.GetProductAsync(getRequest, cancellationToken: ct);

                    context.Logger.LogInformation($"  ✓ Producto encontrado: {product.Name}");

                    // 2. Actualizar producto con nuevas imágenes
                    // NOTA: Incrementamos Stock en 1 solo como indicador de que se procesó la imagen
                    // En producción, aquí se agregarían campos de imagen al proto
                    var updateRequest = new UpdateProductRequest
                    {
                        Id = productId,
                        Name = product.Name,
                        Description = product.Description,
                        Price = product.Price,
                        Stock = product.Stock + 1,  // Indicador de procesamiento
                        Category = product.Category
                    };

                    context.Logger.LogInformation($"  → Actualizando producto...");
                    var updateResponse = await client.UpdateProductAsync(updateRequest, cancellationToken: ct);

                    return updateResponse;

                }, CancellationToken.None);  // ✅ CORREGIDO: usar CancellationToken.None

                // ✅ CORREGIDO: Verificar éxito basándose en que Id > 0 (respuesta válida)
                if (response.Id > 0)
                {
                    context.Logger.LogInformation($"[POLLY] ✅ ProductService actualizado exitosamente");
                    return true;
                }
                else
                {
                    // Esto solo ocurre si el fallback se activó
                    context.Logger.LogWarning($"[POLLY] ⚠️ Fallback activado - ProductService no disponible");
                    return false;
                }
            }
            catch (Exception ex)
            {
                // Si llegamos aquí, algo muy grave pasó (excepción no manejada por Polly)
                context.Logger.LogError($"[POLLY] ❌ Error crítico no manejado: {ex.Message}");
                return false;
            }
        }
    }
}