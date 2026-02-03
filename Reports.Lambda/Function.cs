using System.Text.Json;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.Core;
using Amazon.S3;
using Amazon.S3.Model;
using Microsoft.Data.SqlClient;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;
using StackExchange.Redis;
using QuestContainer = QuestPDF.Infrastructure.IContainer;
// ✅ FIX: Aliases para evitar ambigüedad con System.Reflection.Metadata y System.ComponentModel
using QuestDocument = QuestPDF.Fluent.Document;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace Reports.Lambda
{
    /// <summary>
    /// Lambda function para generación de reportes on-demand con Redis cache.
    /// Implementa Cache-Aside pattern para optimizar queries costosas.
    /// </summary>
    public class Function
    {
        private readonly IAmazonS3 _s3Client;
        private readonly string _connectionString;
        private readonly string _reportsBucket;
        private readonly IConnectionMultiplexer? _redis;
        private readonly IDatabase? _redisDb;

        public Function()
        {
            // ✅ Configurar licencia QuestPDF
            QuestPDF.Settings.License = LicenseType.Community;

            // Configuración de S3 para LocalStack
            var s3Config = new AmazonS3Config
            {
                ServiceURL = Environment.GetEnvironmentVariable("S3_ENDPOINT") ?? "http://localhost:4566",
                ForcePathStyle = true
            };
            _s3Client = new AmazonS3Client(s3Config);

            _connectionString = Environment.GetEnvironmentVariable("SQL_CONNECTION_STRING")
                ?? "Server=localhost,1433;User Id=sa;Password=Password123!;TrustServerCertificate=True;";

            _reportsBucket = Environment.GetEnvironmentVariable("REPORTS_BUCKET") ?? "reports-generated";

            // ✅ NUEVO: Configurar Redis con manejo de errores
            try
            {
                var redisEndpoint = Environment.GetEnvironmentVariable("REDIS_ENDPOINT") ?? "localhost:6379";
                Console.WriteLine($"📦 Conectando a Redis: {redisEndpoint}");

                _redis = ConnectionMultiplexer.Connect(redisEndpoint);
                _redisDb = _redis.GetDatabase();

                Console.WriteLine("✅ Redis conectado correctamente");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"⚠️ Redis no disponible: {ex.Message}");
                Console.WriteLine("⚠️ Continuando sin caché (fallback mode)");
                _redis = null;
                _redisDb = null;
            }
        }

        public Function(IAmazonS3 s3Client, string connectionString, string reportsBucket)
        {
            QuestPDF.Settings.License = LicenseType.Community;
            _s3Client = s3Client;
            _connectionString = connectionString;
            _reportsBucket = reportsBucket;
        }

        public async Task<APIGatewayProxyResponse> FunctionHandler(
            APIGatewayProxyRequest request,
            ILambdaContext context)
        {
            try
            {
                context.Logger.LogInformation("🚀 Generando reporte on-demand");

                // Parsear parámetros
                string reportType = "sales";
                string startDate = DateTime.Now.AddDays(-30).ToString("yyyy-MM-dd");
                string endDate = DateTime.Now.ToString("yyyy-MM-dd");

                if (request.QueryStringParameters != null)
                {
                    if (request.QueryStringParameters.ContainsKey("type"))
                        reportType = request.QueryStringParameters["type"];

                    if (request.QueryStringParameters.ContainsKey("startDate"))
                        startDate = request.QueryStringParameters["startDate"];

                    if (request.QueryStringParameters.ContainsKey("endDate"))
                        endDate = request.QueryStringParameters["endDate"];
                }

                context.Logger.LogInformation($"📊 Tipo: {reportType}, Rango: {startDate} a {endDate}");

                // Validar parámetros
                if (!DateTime.TryParse(startDate, out var start) || !DateTime.TryParse(endDate, out var end))
                {
                    return CreateResponse(400, new { error = "Fechas inválidas. Formato: yyyy-MM-dd" });
                }

                if (start > end)
                {
                    return CreateResponse(400, new { error = "La fecha de inicio debe ser menor a la fecha fin" });
                }

                // ✅ NUEVO: Intentar obtener datos desde caché
                var cacheKey = $"report:{reportType}:{startDate}:{endDate}";
                ReportData? reportData = null;
                bool cacheHit = false;

                if (_redisDb != null)
                {
                    try
                    {
                        var cachedJson = await _redisDb.StringGetAsync(cacheKey);
                        if (cachedJson.HasValue)
                        {
                            reportData = JsonSerializer.Deserialize<ReportData>(cachedJson!);
                            cacheHit = true;
                            context.Logger.LogInformation($"🎯 CACHE HIT: Datos obtenidos desde Redis");
                        }
                        else
                        {
                            context.Logger.LogInformation($"❌ CACHE MISS: Consultando base de datos");
                        }
                    }
                    catch (Exception ex)
                    {
                        context.Logger.LogWarning($"⚠️ Error leyendo caché: {ex.Message}");
                    }
                }

                // Si no hay cache hit, obtener datos de BD
                if (reportData == null)
                {
                    reportData = reportType.ToLower() switch
                    {
                        "sales" => await GenerateSalesReport(start, end, context),
                        "products" => await GenerateProductsReport(start, end, context),
                        "orders" => await GenerateOrdersReport(start, end, context),
                        _ => throw new ArgumentException($"Tipo de reporte no soportado: {reportType}")
                    };

                    // ✅ NUEVO: Guardar en caché con TTL de 10 minutos
                    if (_redisDb != null && reportData != null)
                    {
                        try
                        {
                            var jsonData = JsonSerializer.Serialize(reportData);
                            await _redisDb.StringSetAsync(
                                cacheKey,
                                jsonData,
                                TimeSpan.FromMinutes(10) // TTL: 10 minutos
                            );
                            context.Logger.LogInformation($"💾 Datos guardados en caché (TTL: 10 min)");
                        }
                        catch (Exception ex)
                        {
                            context.Logger.LogWarning($"⚠️ Error guardando en caché: {ex.Message}");
                        }
                    }
                }

                // Generar PDF
                var pdfBytes = GeneratePDF(reportData, reportType, start, end, context);

                // Subir a S3 y obtener URL pre-firmada
                var reportUrl = await UploadToS3AndGetUrl(pdfBytes, reportType, context);

                return CreateResponse(200, new
                {
                    success = true,
                    reportType = reportType,
                    generatedAt = DateTime.UtcNow,
                    downloadUrl = reportUrl,
                    expiresIn = "1 hour",
                    fileSize = pdfBytes.Length,
                    // ✅ NUEVO: Indicar si vino de caché
                    cacheHit = cacheHit,
                    cacheKey = cacheKey
                });
            }
            catch (ArgumentException ex)
            {
                context.Logger.LogError($"Error de validación: {ex.Message}");
                return CreateResponse(400, new { error = ex.Message });
            }
            catch (Exception ex)
            {
                context.Logger.LogError($"Error generando reporte: {ex.Message}\n{ex.StackTrace}");
                return CreateResponse(500, new { error = "Error interno generando el reporte" });
            }
        }

        private async Task<ReportData> GenerateSalesReport(DateTime startDate, DateTime endDate, ILambdaContext context)
        {
            var reportData = new ReportData
            {
                Title = "Reporte de Ventas",
                Period = $"{startDate:dd/MM/yyyy} - {endDate:dd/MM/yyyy}"
            };

            var query = @"
                -- Total de ventas por día
                SELECT 
                    CAST(o.CreatedAt AS DATE) as Fecha,
                    COUNT(DISTINCT o.Id) as TotalOrdenes,
                    COUNT(DISTINCT o.UserId) as ClientesUnicos,
                    SUM(o.TotalAmount) as VentasTotal,
                    AVG(o.TotalAmount) as TicketPromedio
                FROM ECommerceOrders.dbo.Orders o
                WHERE o.CreatedAt >= @StartDate AND o.CreatedAt <= @EndDate
                GROUP BY CAST(o.CreatedAt AS DATE)
                ORDER BY Fecha DESC;

                -- Top 10 productos más vendidos
                SELECT TOP 10
                    oi.ProductName,
                    SUM(oi.Quantity) as CantidadVendida,
                    SUM(oi.Price * oi.Quantity) as IngresoTotal
                FROM ECommerceOrders.dbo.OrderItems oi
                INNER JOIN ECommerceOrders.dbo.Orders o ON oi.OrderId = o.Id
                WHERE o.CreatedAt >= @StartDate AND o.CreatedAt <= @EndDate
                GROUP BY oi.ProductName
                ORDER BY IngresoTotal DESC;

                -- Métodos de pago más utilizados
                SELECT 
                    p.PaymentMethod,
                    COUNT(*) as TotalTransacciones,
                    SUM(p.Amount) as MontoTotal,
                    AVG(p.Amount) as MontoPromedio
                FROM ECommercePayments.dbo.Payments p
                WHERE p.CreatedAt >= @StartDate AND p.CreatedAt <= @EndDate
                    AND p.Status = 'Completed'
                GROUP BY p.PaymentMethod
                ORDER BY TotalTransacciones DESC;
            ";

            using (var connection = new SqlConnection(_connectionString))
            {
                await connection.OpenAsync();
                using (var command = new SqlCommand(query, connection))
                {
                    command.Parameters.AddWithValue("@StartDate", startDate);
                    command.Parameters.AddWithValue("@EndDate", endDate);

                    using (var reader = await command.ExecuteReaderAsync())
                    {
                        // Ventas por día
                        var salesByDay = new List<Dictionary<string, object>>();
                        while (await reader.ReadAsync())
                        {
                            salesByDay.Add(new Dictionary<string, object>
                            {
                                ["Fecha"] = reader.GetDateTime(0).ToString("dd/MM/yyyy"),
                                ["Órdenes"] = reader.GetInt32(1).ToString(),
                                ["Clientes"] = reader.GetInt32(2).ToString(),
                                ["Ventas"] = $"${reader.GetDecimal(3):N2}",
                                ["Ticket Promedio"] = $"${reader.GetDecimal(4):N2}"
                            });
                        }
                        reportData.Sections.Add("Ventas Diarias", salesByDay);

                        // Top productos
                        await reader.NextResultAsync();
                        var topProducts = new List<Dictionary<string, object>>();
                        while (await reader.ReadAsync())
                        {
                            topProducts.Add(new Dictionary<string, object>
                            {
                                ["Producto"] = reader.GetString(0),
                                ["Cantidad"] = reader.GetInt32(1).ToString(),
                                ["Ingreso"] = $"${reader.GetDecimal(2):N2}"
                            });
                        }
                        reportData.Sections.Add("Top 10 Productos", topProducts);

                        // Métodos de pago
                        await reader.NextResultAsync();
                        var paymentMethods = new List<Dictionary<string, object>>();
                        while (await reader.ReadAsync())
                        {
                            paymentMethods.Add(new Dictionary<string, object>
                            {
                                ["Método"] = reader.GetString(0),
                                ["Transacciones"] = reader.GetInt32(1).ToString(),
                                ["Monto Total"] = $"${reader.GetDecimal(2):N2}",
                                ["Monto Promedio"] = $"${reader.GetDecimal(3):N2}"
                            });
                        }
                        reportData.Sections.Add("Métodos de Pago", paymentMethods);
                    }
                }
            }

            context.Logger.LogInformation($"📊 Datos obtenidos: {reportData.Sections.Count} secciones");
            return reportData;
        }

        private async Task<ReportData> GenerateProductsReport(DateTime startDate, DateTime endDate, ILambdaContext context)
        {
            var reportData = new ReportData
            {
                Title = "Reporte de Productos e Inventario",
                Period = $"{startDate:dd/MM/yyyy} - {endDate:dd/MM/yyyy}"
            };

            var query = @"
                -- Productos por categoría
                SELECT 
                    Category as Categoría,
                    COUNT(*) as TotalProductos,
                    AVG(Price) as PrecioPromedio
                FROM ECommerceProducts.dbo.Products
                GROUP BY Category
                ORDER BY TotalProductos DESC;

                -- Productos con stock bajo (menos de 10 unidades)
                SELECT 
                    Name as Producto,
                    Stock as 'Stock Actual',
                    Price as Precio,
                    Category as Categoría
                FROM ECommerceProducts.dbo.Products
                WHERE Stock < 10
                ORDER BY Stock ASC;
            ";

            using (var connection = new SqlConnection(_connectionString))
            {
                await connection.OpenAsync();
                using (var command = new SqlCommand(query, connection))
                {
                    using (var reader = await command.ExecuteReaderAsync())
                    {
                        // Productos por categoría
                        var byCategory = new List<Dictionary<string, object>>();
                        while (await reader.ReadAsync())
                        {
                            byCategory.Add(new Dictionary<string, object>
                            {
                                ["Categoría"] = reader.GetString(0),
                                ["Total"] = reader.GetInt32(1).ToString(),
                                ["Precio Promedio"] = $"${reader.GetDecimal(2):N2}"
                            });
                        }
                        reportData.Sections.Add("Productos por Categoría", byCategory);

                        // Stock bajo
                        await reader.NextResultAsync();
                        var lowStock = new List<Dictionary<string, object>>();
                        while (await reader.ReadAsync())
                        {
                            lowStock.Add(new Dictionary<string, object>
                            {
                                ["Producto"] = reader.GetString(0),
                                ["Stock"] = reader.GetInt32(1).ToString(),
                                ["Precio"] = $"${reader.GetDecimal(2):N2}",
                                ["Categoría"] = reader.GetString(3)
                            });
                        }
                        reportData.Sections.Add("Alerta: Stock Bajo", lowStock);
                    }
                }
            }

            return reportData;
        }

        private async Task<ReportData> GenerateOrdersReport(DateTime startDate, DateTime endDate, ILambdaContext context)
        {
            var reportData = new ReportData
            {
                Title = "Reporte de Órdenes y Sagas",
                Period = $"{startDate:dd/MM/yyyy} - {endDate:dd/MM/yyyy}"
            };

            var query = @"
                -- Órdenes por estado
                SELECT 
                    Status as Estado,
                    COUNT(*) as TotalÓrdenes,
                    SUM(TotalAmount) as MontoTotal
                FROM ECommerceOrders.dbo.Orders
                WHERE CreatedAt >= @StartDate AND CreatedAt <= @EndDate
                GROUP BY Status
                ORDER BY TotalÓrdenes DESC;

                -- Sagas completadas vs fallidas
                SELECT 
                    Status as EstadoSaga,
                    COUNT(*) as Cantidad,
                    AVG(DATEDIFF(SECOND, StartedAt, CompletedAt)) as DuraciónPromedioSeg
                FROM ECommerceOrders.dbo.SagaStates
                WHERE StartedAt >= @StartDate AND StartedAt <= @EndDate
                    AND CompletedAt IS NOT NULL
                GROUP BY Status;
            ";

            using (var connection = new SqlConnection(_connectionString))
            {
                await connection.OpenAsync();
                using (var command = new SqlCommand(query, connection))
                {
                    command.Parameters.AddWithValue("@StartDate", startDate);
                    command.Parameters.AddWithValue("@EndDate", endDate);

                    using (var reader = await command.ExecuteReaderAsync())
                    {
                        // Órdenes por estado
                        var ordersByStatus = new List<Dictionary<string, object>>();
                        while (await reader.ReadAsync())
                        {
                            ordersByStatus.Add(new Dictionary<string, object>
                            {
                                ["Estado"] = reader.GetString(0),
                                ["Total Órdenes"] = reader.GetInt32(1).ToString(),
                                ["Monto Total"] = $"${reader.GetDecimal(2):N2}"
                            });
                        }
                        reportData.Sections.Add("Órdenes por Estado", ordersByStatus);

                        // Sagas
                        await reader.NextResultAsync();
                        var sagas = new List<Dictionary<string, object>>();
                        while (await reader.ReadAsync())
                        {
                            sagas.Add(new Dictionary<string, object>
                            {
                                ["Estado"] = reader.GetString(0),
                                ["Cantidad"] = reader.GetInt32(1).ToString(),
                                ["Duración Promedio"] = $"{reader.GetInt32(2)}s"
                            });
                        }
                        reportData.Sections.Add("Métricas de Sagas", sagas);
                    }
                }
            }

            return reportData;
        }

        private byte[] GeneratePDF(ReportData? data, string reportType, DateTime startDate, DateTime endDate, ILambdaContext context)
        {
            if (data == null) throw new ArgumentNullException(nameof(data));

            context.Logger.LogInformation("📄 Generando PDF con QuestPDF");

            var document = QuestDocument.Create(container =>
            {
                container.Page(page =>
                {
                    page.Size(PageSizes.Letter);
                    page.Margin(2, Unit.Centimetre);
                    page.PageColor(Colors.White);
                    page.DefaultTextStyle(x => x.FontSize(11));

                    page.Header().Element(ComposeHeader);
                    page.Content().Element(container => ComposeContent(container, data));
                    page.Footer().AlignCenter().Text(text =>
                    {
                        text.Span("Generado el ");
                        text.Span($"{DateTime.Now:dd/MM/yyyy HH:mm}").SemiBold();
                        text.Span(" | Página ");
                        text.CurrentPageNumber();
                        text.Span(" de ");
                        text.TotalPages();
                    });
                });
            });

            var pdfBytes = document.GeneratePdf();
            context.Logger.LogInformation($"✅ PDF generado: {pdfBytes.Length} bytes");
            return pdfBytes;

            void ComposeHeader(QuestContainer container)
            {
                container.Row(row =>
                {
                    row.RelativeItem().Column(column =>
                    {
                        column.Item().Text(data.Title).FontSize(20).SemiBold().FontColor(Colors.Blue.Darken2);
                        column.Item().Text($"Período: {data.Period}").FontSize(12);
                        column.Item().Text("E-Commerce System").FontSize(10).Italic();
                    });

                    row.ConstantItem(100).Height(50).Placeholder();
                });
            }

            void ComposeContent(QuestContainer container, ReportData data)
            {
                container.Column(outerColumn =>
                {
                    foreach (var section in data.Sections)
                    {
                        outerColumn.Item().PaddingTop(15).Text(section.Key).FontSize(14).SemiBold();

                        if (section.Value.Any())
                        {
                            var firstRow = section.Value.First();
                            var headers = firstRow.Keys.ToList();

                            outerColumn.Item().Table(table =>
                            {
                                table.ColumnsDefinition(columns =>
                                {
                                    foreach (var _ in headers)
                                    {
                                        columns.RelativeColumn();
                                    }
                                });

                                table.Header(header =>
                                {
                                    foreach (var h in headers)
                                    {
                                        header.Cell().Element(CellStyle).Text(h).SemiBold();
                                    }

                                    static QuestContainer CellStyle(QuestContainer container)
                                    {
                                        return container.DefaultTextStyle(x => x.SemiBold())
                                            .PaddingVertical(5).BorderBottom(1).BorderColor(Colors.Black);
                                    }
                                });

                                foreach (var row in section.Value)
                                {
                                    foreach (var header in headers)
                                    {
                                        table.Cell().Element(CellStyle).Text(row[header]?.ToString() ?? "");
                                    }

                                    static QuestContainer CellStyle(QuestContainer container)
                                    {
                                        return container.BorderBottom(1).BorderColor(Colors.Grey.Lighten2)
                                            .PaddingVertical(3);
                                    }
                                }
                            });
                        }
                        else
                        {
                            outerColumn.Item().Text("No hay datos para mostrar").Italic();
                        }
                    }
                });
            }
        }

        private async Task<string> UploadToS3AndGetUrl(byte[] pdfBytes, string reportType, ILambdaContext context)
        {
            var fileName = $"{reportType}_{DateTime.UtcNow:yyyyMMdd_HHmmss}.pdf";
            var key = $"reports/{DateTime.UtcNow:yyyy/MM}/{fileName}";

            context.Logger.LogInformation($"📤 Subiendo a S3: {key}");

            using (var stream = new MemoryStream(pdfBytes))
            {
                var putRequest = new PutObjectRequest
                {
                    BucketName = _reportsBucket,
                    Key = key,
                    InputStream = stream,
                    ContentType = "application/pdf"
                };

                await _s3Client.PutObjectAsync(putRequest);
            }

            var urlRequest = new GetPreSignedUrlRequest
            {
                BucketName = _reportsBucket,
                Key = key,
                Expires = DateTime.UtcNow.AddHours(1)
            };

            var s3Endpoint = Environment.GetEnvironmentVariable("S3_ENDPOINT") ?? "http://localhost:4566";
            var preSignedUrl = _s3Client.GetPreSignedURL(urlRequest);

            // Fix para LocalStack: reemplazar hostname interno
            var fixedUrl = preSignedUrl.Replace("localstack", "localhost");

            context.Logger.LogInformation($"✅ URL generada (válida 1 hora)");
            return fixedUrl;
        }

        private APIGatewayProxyResponse CreateResponse(int statusCode, object body)
        {
            return new APIGatewayProxyResponse
            {
                StatusCode = statusCode,
                Body = JsonSerializer.Serialize(body),
                Headers = new Dictionary<string, string>
                {
                    { "Content-Type", "application/json" },
                    { "Access-Control-Allow-Origin", "*" }
                }
            };
        }
    }

    // Modelo para datos del reporte (serializable para Redis)
    public class ReportData
    {
        public string Title { get; set; } = "";
        public string Period { get; set; } = "";
        public Dictionary<string, List<Dictionary<string, object>>> Sections { get; set; } = new();
    }
}