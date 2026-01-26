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

// Assembly attribute para especificar el serializador JSON de Lambda
[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace ImageProcessor.Lambda
{
    /// <summary>
    /// Lambda function para procesar imágenes de productos.
    /// Se dispara cuando se sube una imagen a S3 y:
    /// 1. Genera thumbnails (200x200, 400x400)
    /// 2. Optimiza la imagen original
    /// 3. Actualiza el ProductService vía gRPC con las URLs de las imágenes
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
        /// Handler principal de la función Lambda
        /// Procesa eventos de S3 cuando se suben imágenes de productos
        /// </summary>
        public async Task<string> FunctionHandler(S3Event s3Event, ILambdaContext context)
        {
            var processedCount = 0;
            var errors = new List<string>();

            context.Logger.LogInformation($"Procesando {s3Event.Records.Count} eventos de S3");

            foreach (var record in s3Event.Records)
            {
                try
                {
                    var bucketName = record.S3.Bucket.Name;
                    var objectKey = record.S3.Object.Key;

                    context.Logger.LogInformation($"Procesando imagen: {bucketName}/{objectKey}");

                    // Validar que sea una imagen
                    if (!IsValidImageFile(objectKey))
                    {
                        context.Logger.LogWarning($"Archivo ignorado (no es imagen): {objectKey}");
                        continue;
                    }

                    // Extraer ProductId del nombre del archivo
                    // Formato esperado: products/{productId}/original.jpg
                    var productId = ExtractProductIdFromKey(objectKey);
                    if (productId == 0)
                    {
                        context.Logger.LogWarning($"No se pudo extraer ProductId de: {objectKey}");
                        continue;
                    }

                    // Descargar imagen original de S3
                    var imageStream = await DownloadImageFromS3(bucketName, objectKey);

                    // Procesar imagen: generar thumbnails y optimizar
                    var processedImages = await ProcessImage(imageStream, context);

                    // Subir imágenes procesadas a S3
                    var imageUrls = await UploadProcessedImages(processedImages, productId, context);

                    // Actualizar ProductService con las URLs de las imágenes vía gRPC
                    await UpdateProductImages(productId, imageUrls, context);

                    processedCount++;
                    context.Logger.LogInformation($"✓ Imagen procesada exitosamente: ProductId={productId}");
                }
                catch (Exception ex)
                {
                    var errorMsg = $"Error procesando {record.S3.Object.Key}: {ex.Message}";
                    context.Logger.LogError(errorMsg);
                    errors.Add(errorMsg);
                }
            }

            var result = new
            {
                ProcessedCount = processedCount,
                TotalRecords = s3Event.Records.Count,
                Errors = errors,
                Timestamp = DateTime.UtcNow
            };

            context.Logger.LogInformation($"Procesamiento completado: {processedCount}/{s3Event.Records.Count} exitosos");

            return JsonSerializer.Serialize(result);
        }

        /// <summary>
        /// Valida si el archivo es una imagen soportada
        /// </summary>
        private bool IsValidImageFile(string fileName)
        {
            var validExtensions = new[] { ".jpg", ".jpeg", ".png", ".webp", ".gif" };
            var extension = Path.GetExtension(fileName).ToLowerInvariant();
            return validExtensions.Contains(extension);
        }

        /// <summary>
        /// Extrae el ProductId del object key de S3
        /// Formato esperado: products/{productId}/original.jpg
        /// </summary>
        private int ExtractProductIdFromKey(string objectKey)
        {
            try
            {
                var parts = objectKey.Split('/');
                if (parts.Length >= 2 && parts[0] == "products")
                {
                    if (int.TryParse(parts[1], out int productId))
                    {
                        return productId;
                    }
                }
            }
            catch
            {
                // Ignorar errores de parsing
            }
            return 0;
        }

        /// <summary>
        /// Descarga la imagen desde S3
        /// </summary>
        private async Task<Stream> DownloadImageFromS3(string bucket, string key)
        {
            var request = new GetObjectRequest
            {
                BucketName = bucket,
                Key = key
            };

            var response = await _s3Client.GetObjectAsync(request);
            var memoryStream = new MemoryStream();
            await response.ResponseStream.CopyToAsync(memoryStream);
            memoryStream.Position = 0;
            return memoryStream;
        }

        /// <summary>
        /// Procesa la imagen: genera thumbnails y optimiza
        /// Retorna diccionario con las imágenes procesadas
        /// </summary>
        private async Task<Dictionary<string, Stream>> ProcessImage(Stream imageStream, ILambdaContext context)
        {
            var results = new Dictionary<string, Stream>();

            using (var image = await Image.LoadAsync(imageStream))
            {
                context.Logger.LogInformation($"Imagen cargada: {image.Width}x{image.Height}");

                // 1. Thumbnail pequeño (200x200)
                var thumbnail200 = image.Clone(ctx => ctx.Resize(new ResizeOptions
                {
                    Size = new Size(200, 200),
                    Mode = ResizeMode.Crop
                }));
                var stream200 = new MemoryStream();
                await thumbnail200.SaveAsJpegAsync(stream200, new JpegEncoder { Quality = 85 });
                stream200.Position = 0;
                results["thumbnail_200"] = stream200;

                // 2. Thumbnail mediano (400x400)
                var thumbnail400 = image.Clone(ctx => ctx.Resize(new ResizeOptions
                {
                    Size = new Size(400, 400),
                    Mode = ResizeMode.Crop
                }));
                var stream400 = new MemoryStream();
                await thumbnail400.SaveAsJpegAsync(stream400, new JpegEncoder { Quality = 90 });
                stream400.Position = 0;
                results["thumbnail_400"] = stream400;

                // 3. Imagen optimizada (máximo 1200px, mantener aspect ratio)
                var optimized = image.Clone(ctx =>
                {
                    if (image.Width > 1200 || image.Height > 1200)
                    {
                        ctx.Resize(new ResizeOptions
                        {
                            Size = new Size(1200, 1200),
                            Mode = ResizeMode.Max
                        });
                    }
                });
                var streamOptimized = new MemoryStream();
                await optimized.SaveAsJpegAsync(streamOptimized, new JpegEncoder { Quality = 92 });
                streamOptimized.Position = 0;
                results["optimized"] = streamOptimized;

                context.Logger.LogInformation($"Generadas 3 versiones de la imagen");
            }

            return results;
        }

        /// <summary>
        /// Sube las imágenes procesadas a S3
        /// Retorna las URLs de las imágenes
        /// </summary>
        private async Task<Dictionary<string, string>> UploadProcessedImages(
            Dictionary<string, Stream> images,
            int productId,
            ILambdaContext context)
        {
            var urls = new Dictionary<string, string>();

            foreach (var kvp in images)
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

                context.Logger.LogInformation($"Subida: {key}");
            }

            return urls;
        }

        /// <summary>
        /// Actualiza el ProductService vía gRPC con las URLs de las imágenes
        /// </summary>
        private async Task UpdateProductImages(
            int productId,
            Dictionary<string, string> imageUrls,
            ILambdaContext context)
        {
            try
            {
                var client = new ProductService.ProductServiceClient(_grpcChannel);

                // Primero obtener el producto actual
                var getRequest = new GetProductRequest { Id = productId };
                var product = await client.GetProductAsync(getRequest);

                context.Logger.LogInformation($"Producto encontrado: {product.Name}");

                // Actualizar con las nuevas URLs de imágenes
                // Nota: Esto requiere que el proto tenga campos de imagen
                // Si no existe, este es un ejemplo de cómo se haría
                var updateRequest = new UpdateProductRequest
                {
                    Id = productId,
                    Name = product.Name,
                    Description = product.Description,
                    Price = product.Price,
                    Stock = product.Stock+1,
                    Category = product.Category,
                    // Aquí se agregarían los campos de imagen si existieran en el proto
                    // ImageUrl = imageUrls["optimized"],
                    // ThumbnailUrl = imageUrls["thumbnail_200"],
                    // MediumImageUrl = imageUrls["thumbnail_400"]
                };

                var response = await client.UpdateProductAsync(updateRequest);

                context.Logger.LogInformation($"✓ ProductService actualizado para ProductId={productId}");
            }
            catch (Exception ex)
            {
                context.Logger.LogError($"Error al actualizar ProductService: {ex.Message}");
                throw;
            }
        }
    }
}
