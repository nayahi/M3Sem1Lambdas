using Amazon.Lambda.Core;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.S3;
using Amazon.S3.Model;
using Microsoft.Data.SqlClient;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;
using System.Text.Json;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace Reports.Lambda
{
    /// <summary>
    /// Lambda function para generación de reportes on-demand.
    /// </summary>
    public class Function
    {
        private readonly IAmazonS3 _s3Client;
        private readonly string _connectionString;
        private readonly string _reportsBucket;

        public Function()
        {
            // ✅ CRÍTICO: Configurar licencia QuestPDF
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
                context.Logger.LogInformation("Generando reporte on-demand");

                // ✅ FIX: Parsear parámetros correctamente
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

                context.Logger.LogInformation($"Tipo: {reportType}, Rango: {startDate} a {endDate}");

                // Validar parámetros
                if (!DateTime.TryParse(startDate, out var start) || !DateTime.TryParse(endDate, out var end))
                {
                    return CreateResponse(400, new { error = "Fechas inválidas. Formato: yyyy-MM-dd" });
                }

                if (start > end)
                {
                    return CreateResponse(400, new { error = "La fecha de inicio debe ser menor a la fecha fin" });
                }

                // Obtener datos según el tipo de reporte
                var reportData = reportType.ToLower() switch
                {
                    "sales" => await GenerateSalesReport(start, end, context),
                    "products" => await GenerateProductsReport(start, end, context),
                    "orders" => await GenerateOrdersReport(start, end, context),
                    _ => throw new ArgumentException($"Tipo de reporte no soportado: {reportType}")
                };

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
                    fileSize = pdfBytes.Length
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
                WHERE o.CreatedAt >= @StartDate 
                    AND o.CreatedAt <= @EndDate
                    AND o.Status IN ('Completed', 'Processing')
                GROUP BY CAST(o.CreatedAt AS DATE)
                ORDER BY Fecha DESC;

                -- Ventas por categoría de producto
                SELECT TOP 10
                    oi.ProductName,
                    SUM(oi.Quantity) as CantidadVendida,
                    SUM(oi.Quantity * oi.UnitPrice) as IngresoTotal
                FROM ECommerceOrders.dbo.OrderItems oi
                INNER JOIN ECommerceOrders.dbo.Orders o ON oi.OrderId = o.Id
                WHERE o.CreatedAt >= @StartDate 
                    AND o.CreatedAt <= @EndDate
                    AND o.Status IN ('Completed', 'Processing')
                GROUP BY oi.ProductName
                ORDER BY IngresoTotal DESC;

                -- Métodos de pago más usados
                SELECT 
                    p.PaymentMethod,
                    COUNT(*) as TotalTransacciones,
                    SUM(p.Amount) as MontoTotal,
                    AVG(p.Amount) as MontoPromedio
                FROM ECommercePayments.dbo.Payments p
                WHERE p.CreatedAt >= @StartDate 
                    AND p.CreatedAt <= @EndDate
                    AND p.Status = 'Completed'
                GROUP BY p.PaymentMethod
                ORDER BY MontoTotal DESC;
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
                        // ✅ FIX: Leer ventas diarias con conversiones correctas
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

                        // ✅ FIX: Leer top productos
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

                        // ✅ FIX: Leer métodos de pago
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

            context.Logger.LogInformation($"Datos obtenidos: {reportData.Sections.Count} secciones");
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
                    SUM(Stock) as InventarioTotal,
                    AVG(Price) as PrecioPromedio
                FROM ECommerceGRPCProducts.dbo.Products
                WHERE IsActive = 1
                GROUP BY Category
                ORDER BY TotalProductos DESC;

                -- Productos con stock bajo
                SELECT TOP 20
                    Name as Producto,
                    Category as Categoría,
                    Stock as Inventario,
                    Price as Precio
                FROM ECommerceGRPCProducts.dbo.Products
                WHERE IsActive = 1 AND Stock < 50
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
                                ["Productos"] = reader.GetInt32(1).ToString(),
                                ["Stock Total"] = reader.GetInt32(2).ToString(),
                                ["Precio Promedio"] = $"${reader.GetDecimal(3):N2}"
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
                                ["Categoría"] = reader.GetString(1),
                                ["Stock"] = reader.GetInt32(2).ToString(),
                                ["Precio"] = $"${reader.GetDecimal(3):N2}"
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

        private byte[] GeneratePDF(ReportData data, string reportType, DateTime startDate, DateTime endDate, ILambdaContext context)
        {
            context.Logger.LogInformation("Generando PDF con QuestPDF");

            var document = Document.Create(container =>
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
            context.Logger.LogInformation($"PDF generado: {pdfBytes.Length} bytes");
            return pdfBytes;

            void ComposeHeader(IContainer container)
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

            // ✅ CORRECCIÓN: Llamar Column UNA SOLA VEZ, loop dentro
            void ComposeContent(IContainer container, ReportData data)
            {
                container.Column(outerColumn =>  // ✅ UNA SOLA VEZ
                {
                    foreach (var section in data.Sections)  // ✅ LOOP DENTRO
                    {
                        // Título de sección
                        outerColumn.Item().PaddingTop(15).Text(section.Key).FontSize(14).SemiBold();

                        if (section.Value.Any())
                        {
                            var firstRow = section.Value.First();
                            var headers = firstRow.Keys.ToList();

                            // Tabla
                            outerColumn.Item().Table(table =>
                            {
                                // Definir columnas
                                table.ColumnsDefinition(columns =>
                                {
                                    foreach (var _ in headers)
                                    {
                                        columns.RelativeColumn();
                                    }
                                });

                                // Header de tabla
                                table.Header(header =>
                                {
                                    foreach (var h in headers)
                                    {
                                        header.Cell().Element(CellStyle).Text(h).SemiBold();
                                    }

                                    static IContainer CellStyle(IContainer container)
                                    {
                                        return container.DefaultTextStyle(x => x.SemiBold())
                                            .PaddingVertical(5).BorderBottom(1).BorderColor(Colors.Black);
                                    }
                                });

                                // Rows de tabla
                                foreach (var row in section.Value)
                                {
                                    foreach (var header in headers)
                                    {
                                        table.Cell().Element(CellStyle).Text(row[header]?.ToString() ?? "");
                                    }

                                    static IContainer CellStyle(IContainer container)
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

            context.Logger.LogInformation($"Subiendo a S3: {key}");

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

            // ✅ CORRECCIÓN: Generar URL accesible desde fuera de Docker
            var s3Endpoint = Environment.GetEnvironmentVariable("S3_ENDPOINT") ?? "http://localhost:4566";

            var downloadUrl = _s3Client.GetPreSignedURL(urlRequest);
            context.Logger.LogInformation($"Download URL generada (interna a docker): {downloadUrl}");

            // ✅ IMPORTANTE: Reemplazar endpoint interno con externo
            var url = downloadUrl.Replace("http://localstack:4566", "http://localhost:4566")
                                     .Replace("https://localstack:4566", "http://localhost:4566");

            context.Logger.LogInformation($"URL generada (externa a docker): {url}");

            return url;
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

    public class ReportData
    {
        public string Title { get; set; } = string.Empty;
        public string Period { get; set; } = string.Empty;
        public Dictionary<string, List<Dictionary<string, object>>> Sections { get; set; } = new();
    }
}