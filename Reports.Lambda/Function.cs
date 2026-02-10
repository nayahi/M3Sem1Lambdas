using System.Security.Cryptography;              // ✅ SEMANA 4: Para SHA256 (audit log hash chain)
using System.Text;                               // ✅ SEMANA 4: Para Encoding (JWT decode + hash)
using System.Text.Json;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.Core;
using Amazon.S3;
using Amazon.S3.Model;
using Amazon.SecretsManager;                     // ✅ SEMANA 4: Secrets Manager
using Amazon.SecretsManager.Model;               // ✅ SEMANA 4: GetSecretValueRequest
using Microsoft.Data.SqlClient;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;
using StackExchange.Redis;
using QuestContainer = QuestPDF.Infrastructure.IContainer;
// ✅ FIX: Aliases para evitar ambigüedad
using QuestDocument = QuestPDF.Fluent.Document;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace Reports.Lambda
{
    /// <summary>
    /// Lambda function para generación de reportes on-demand con Redis cache.
    /// 
    /// Semana 1: API Gateway + SQL Server + QuestPDF + S3
    /// Semana 2: Polly (resiliencia)
    /// Semana 3: Redis Cache-Aside
    /// Semana 4: Secrets Manager + JWT Validation + Audit Log (hash chain)
    /// </summary>
    public class Function
    {
        private readonly IAmazonS3 _s3Client;
        private readonly string _connectionString;
        private readonly string _reportsBucket;
        private readonly IConnectionMultiplexer? _redis;
        private readonly IDatabase? _redisDb;

        // ✅ SEMANA 4: Secrets Manager
        private readonly IAmazonSecretsManager _secretsClient;
        private readonly string _secretName;
        private string? _cachedConnectionString;

        // ✅ SEMANA 4: JWT
        private readonly string _expectedIssuer;

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
                Console.WriteLine($"📦 Intentando conectar a Redis: {redisEndpoint}");

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

            // ✅ SEMANA 4: Secrets Manager client (solo crear cliente, NO hacer I/O)
            var smEndpoint = Environment.GetEnvironmentVariable("SECRETS_ENDPOINT")
                ?? "http://localstack:4566";
            _secretsClient = new AmazonSecretsManagerClient(
                new AmazonSecretsManagerConfig { ServiceURL = smEndpoint });
            _secretName = Environment.GetEnvironmentVariable("SQL_SECRET_NAME")
                ?? "ecommerce/sql-connection";

            // ✅ SEMANA 4: JWT issuer esperado de Keycloak
            _expectedIssuer = Environment.GetEnvironmentVariable("JWT_ISSUER")
                ?? "http://keycloak:8080/realms/ecommerce";
        }

        public Function(IAmazonS3 s3Client, string connectionString, string reportsBucket)
        {
            QuestPDF.Settings.License = LicenseType.Community;
            _s3Client = s3Client;
            _connectionString = connectionString;
            _reportsBucket = reportsBucket;

            // ✅ SEMANA 4: Defaults para testing
            _secretsClient = new AmazonSecretsManagerClient(
                new AmazonSecretsManagerConfig { ServiceURL = "http://localhost:4566" });
            _secretName = "ecommerce/sql-connection";
            _expectedIssuer = "http://keycloak:8080/realms/ecommerce";
        }

        // =============================================================
        // ✅ SEMANA 4 - SECRETS MANAGER
        // =============================================================

        /// <summary>
        /// Obtiene connection string de Secrets Manager con fallback a env var.
        /// Cachea en memoria para reutilizar en Lambda warm.
        /// </summary>
        private async Task<string> GetConnectionStringAsync(ILambdaContext context)
        {
            // Si ya lo tenemos en memoria, reutilizar (Lambda warm)
            if (_cachedConnectionString != null)
            {
                context.Logger.LogInformation("🔑 Connection string: usando caché en memoria");
                return _cachedConnectionString;
            }

            try
            {
                var response = await _secretsClient.GetSecretValueAsync(
                    new GetSecretValueRequest { SecretId = _secretName });

                _cachedConnectionString = response.SecretString;
                context.Logger.LogInformation(
                    $"🔐 Connection string obtenido de Secrets Manager (secreto: {_secretName})");
                return _cachedConnectionString;
            }
            catch (Exception ex)
            {
                // Fallback: variable de ambiente (como en semanas anteriores)
                context.Logger.LogWarning(
                    $"⚠️ Secrets Manager no disponible ({ex.Message}). Usando fallback env var.");
                _cachedConnectionString = _connectionString;
                return _cachedConnectionString;
            }
        }

        // =============================================================
        // ✅ SEMANA 4 - JWT VALIDATION
        // =============================================================

        /// <summary>
        /// Valida el JWT del header Authorization.
        /// NOTA EDUCATIVA: En producción usar Microsoft.IdentityModel.Tokens
        /// con verificación criptográfica completa. Aquí decodificamos el payload
        /// para demostrar la estructura de un JWT y validaciones básicas.
        /// </summary>
        private (bool isValid, string userId, string? error) ValidateJwtToken(
            APIGatewayProxyRequest request, ILambdaContext context)
        {
            // 1. Buscar header Authorization (IDictionary, usar foreach)
            string? authHeader = null;
            if (request.Headers != null)
            {
                foreach (var h in request.Headers)
                {
                    if (h.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase))
                    {
                        authHeader = h.Value;
                        break;
                    }
                }
            }

            if (string.IsNullOrEmpty(authHeader) || !authHeader.StartsWith("Bearer "))
            {
                return (false, "anonymous", "Missing or invalid Authorization header");
            }

            var token = authHeader.Substring("Bearer ".Length);

            try
            {
                // 2. Decodificar JWT (3 partes: header.payload.signature)
                var parts = token.Split('.');
                if (parts.Length != 3)
                {
                    return (false, "anonymous", "Token JWT malformado: se esperan 3 segmentos");
                }

                // 3. Decodificar payload (parte 2, base64url)
                var payloadJson = DecodeBase64Url(parts[1]);
                var payload = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(payloadJson);

                if (payload == null)
                {
                    return (false, "anonymous", "No se pudo deserializar el payload del JWT");
                }

                // 4. Validar expiración (claim "exp")
                if (payload.TryGetValue("exp", out var expElement))
                {
                    var expUnix = expElement.GetInt64();
                    var expDate = DateTimeOffset.FromUnixTimeSeconds(expUnix);
                    if (expDate < DateTimeOffset.UtcNow)
                    {
                        return (false, "anonymous", $"Token expirado: {expDate:u}");
                    }
                }

                // 5. Validar issuer (claim "iss") - solo warning, no rechazar en demo
                if (payload.TryGetValue("iss", out var issElement))
                {
                    var issuer = issElement.GetString();
                    if (issuer != _expectedIssuer)
                    {
                        context.Logger.LogWarning(
                            $"⚠️ Issuer no coincide. Esperado: {_expectedIssuer}, Recibido: {issuer}");
                    }
                }

                // 6. Extraer identidad del usuario/servicio
                var userId = "unknown";
                if (payload.TryGetValue("preferred_username", out var userEl))
                    userId = userEl.GetString() ?? "unknown";
                else if (payload.TryGetValue("client_id", out var clientEl))
                    userId = clientEl.GetString() ?? "unknown";
                else if (payload.TryGetValue("sub", out var subEl))
                    userId = subEl.GetString() ?? "unknown";

                context.Logger.LogInformation($"🔓 JWT válido. Usuario/Servicio: {userId}");
                return (true, userId, null);
            }
            catch (Exception ex)
            {
                return (false, "anonymous", $"Error decodificando JWT: {ex.Message}");
            }
        }

        /// <summary>
        /// Decodifica un string Base64Url (usado en JWT).
        /// </summary>
        private static string DecodeBase64Url(string base64Url)
        {
            var base64 = base64Url.Replace('-', '+').Replace('_', '/');
            switch (base64.Length % 4)
            {
                case 2: base64 += "=="; break;
                case 3: base64 += "="; break;
            }
            return Encoding.UTF8.GetString(Convert.FromBase64String(base64));
        }

        // =============================================================
        // ✅ SEMANA 4 - AUDIT LOG CON HASH CHAIN
        // =============================================================

        /// <summary>
        /// Escribe entrada de auditoría con hash chain inmutable.
        /// Hash = SHA256(previousHash + "|" + action + "|" + userId + "|" + timestamp + "|" + details)
        /// Primera entrada usa "genesis" como previousHash.
        /// </summary>
        private async Task WriteAuditLogAsync(
            string action, string userId, string resourceType,
            string details, string connString, ILambdaContext context)
        {
            try
            {
                using var connection = new SqlConnection(connString);
                await connection.OpenAsync();

                // 1. Obtener hash del último registro
                var previousHash = "genesis";
                using (var cmd = new SqlCommand(
                    "SELECT TOP 1 Hash FROM ECommerceOrders.dbo.AuditLog ORDER BY Id DESC",
                    connection))
                {
                    var result = await cmd.ExecuteScalarAsync();
                    if (result != null && result != DBNull.Value)
                        previousHash = result.ToString()!;
                }

                // 2. Calcular hash de esta entrada
                var timestamp = DateTime.UtcNow;
                var dataToHash = $"{previousHash}|{action}|{userId}|{timestamp:O}|{details}";
                var hash = ComputeSha256(dataToHash);

                // 3. Insertar registro
                using (var cmd = new SqlCommand(@"
                    INSERT INTO ECommerceOrders.dbo.AuditLog 
                        (Action, UserId, ResourceType, Details, Hash, PreviousHash, CreatedAt)
                    VALUES 
                        (@Action, @UserId, @ResourceType, @Details, @Hash, @PreviousHash, @CreatedAt)",
                    connection))
                {
                    cmd.Parameters.AddWithValue("@Action", action);
                    cmd.Parameters.AddWithValue("@UserId", userId);
                    cmd.Parameters.AddWithValue("@ResourceType", resourceType);
                    cmd.Parameters.AddWithValue("@Details", details);
                    cmd.Parameters.AddWithValue("@Hash", hash);
                    cmd.Parameters.AddWithValue("@PreviousHash", previousHash);
                    cmd.Parameters.AddWithValue("@CreatedAt", timestamp);
                    await cmd.ExecuteNonQueryAsync();
                }

                context.Logger.LogInformation(
                    $"📋 Audit log: {action} por {userId} | Hash: {hash[..12]}...");
            }
            catch (Exception ex)
            {
                // Audit log NO debe romper el flujo principal
                context.Logger.LogWarning($"⚠️ Error escribiendo audit log: {ex.Message}");
            }
        }

        private static string ComputeSha256(string input)
        {
            var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(input));
            return Convert.ToHexString(bytes).ToLowerInvariant();
        }

        // =============================================================
        // HANDLER PRINCIPAL (original + Semana 4)
        // =============================================================

        public async Task<APIGatewayProxyResponse> FunctionHandler(
            APIGatewayProxyRequest request,
            ILambdaContext context)
        {
            try
            {
                context.Logger.LogInformation("🚀 Generando reporte on-demand (Semana 4: Seguridad)");

                // ─── ✅ SEMANA 4: Validar JWT ───
                var (isValid, userId, jwtError) = ValidateJwtToken(request, context);

                if (!isValid)
                {
                    context.Logger.LogWarning($"🚫 Acceso denegado: {jwtError}");

                    // Auditar intento fallido (usando _connectionString directo como fallback)
                    await WriteAuditLogAsync(
                        "REPORT_ACCESS_DENIED", "anonymous", "N/A",
                        $"JWT inválido: {jwtError}", _connectionString, context);

                    return CreateResponse(401, new
                    {
                        error = "No autorizado",
                        detail = jwtError
                    });
                }

                // ─── ✅ SEMANA 4: Obtener connection string de Secrets Manager ───
                var connectionString = await GetConnectionStringAsync(context);

                // ─── Parsear parámetros (SIN CAMBIOS) ───
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

                context.Logger.LogInformation(
                    $"📊 Tipo: {reportType}, Rango: {startDate} a {endDate}, Usuario: {userId}");

                // Validar parámetros (SIN CAMBIOS)
                if (!DateTime.TryParse(startDate, out var start) || !DateTime.TryParse(endDate, out var end))
                {
                    return CreateResponse(400, new { error = "Fechas inválidas. Formato: yyyy-MM-dd" });
                }

                if (start > end)
                {
                    return CreateResponse(400, new { error = "La fecha de inicio debe ser menor a la fecha fin" });
                }

                // ✅ Intentar obtener datos desde caché (SIN CAMBIOS)
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
                else
                {
                    context.Logger.LogInformation("⚠️ Redis no disponible - consultando BD directamente");
                }

                // Si no hay cache hit, obtener datos de BD
                // ✅ SEMANA 4: Usa connectionString de Secrets Manager (no _connectionString directo)
                if (reportData == null)
                {
                    reportData = reportType.ToLower() switch
                    {
                        "sales" => await GenerateSalesReport(start, end, connectionString, context),
                        "products" => await GenerateProductsReport(start, end, connectionString, context),
                        "orders" => await GenerateOrdersReport(start, end, connectionString, context),
                        _ => throw new ArgumentException($"Tipo de reporte no soportado: {reportType}")
                    };

                    // Guardar en caché con TTL de 10 minutos (SIN CAMBIOS)
                    if (_redisDb != null && reportData != null)
                    {
                        try
                        {
                            var jsonData = JsonSerializer.Serialize(reportData);
                            await _redisDb.StringSetAsync(
                                cacheKey,
                                jsonData,
                                TimeSpan.FromMinutes(10)
                            );
                            context.Logger.LogInformation($"💾 Datos guardados en caché (TTL: 10 min)");
                        }
                        catch (Exception ex)
                        {
                            context.Logger.LogWarning($"⚠️ Error guardando en caché: {ex.Message}");
                        }
                    }
                }

                // Generar PDF (SIN CAMBIOS)
                var pdfBytes = GeneratePDF(reportData, reportType, start, end, context);

                // Subir a S3 y obtener URL pre-firmada (SIN CAMBIOS)
                var reportUrl = await UploadToS3AndGetUrl(pdfBytes, reportType, context);

                // ─── ✅ SEMANA 4: Escribir Audit Log ───
                await WriteAuditLogAsync(
                    "REPORT_GENERATED", userId, reportType,
                    $"Período: {startDate} - {endDate} | Tamaño: {pdfBytes.Length} bytes | Cache: {cacheHit}",
                    connectionString, context);

                return CreateResponse(200, new
                {
                    success = true,
                    reportType = reportType,
                    generatedAt = DateTime.UtcNow,
                    generatedBy = userId,          // ✅ SEMANA 4: quién generó el reporte
                    downloadUrl = reportUrl,
                    expiresIn = "1 hour",
                    fileSize = pdfBytes.Length,
                    cacheHit = cacheHit,
                    cacheKey = _redisDb != null ? cacheKey : null
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

        // =============================================================
        // REPORTES SQL (código original, solo se agrega parámetro connectionString)
        // =============================================================

        // ✅ SEMANA 4: Único cambio en estos métodos = reciben connectionString como parámetro
        //    en lugar de usar _connectionString directamente. Así usan el valor de Secrets Manager.

        private async Task<ReportData> GenerateSalesReport(
            DateTime startDate, DateTime endDate, string connectionString, ILambdaContext context)
        {
            var reportData = new ReportData
            {
                Title = "Reporte de Ventas",
                Period = $"{startDate:dd/MM/yyyy} - {endDate:dd/MM/yyyy}"
            };

            // ✅ NOMBRES DE BD CORRECTOS: ECommerceOrders, ECommercePayments
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

            using (var connection = new SqlConnection(connectionString))
            {
                await connection.OpenAsync();
                using (var command = new SqlCommand(query, connection))
                {
                    command.Parameters.AddWithValue("@StartDate", startDate);
                    command.Parameters.AddWithValue("@EndDate", endDate);

                    using (var reader = await command.ExecuteReaderAsync())
                    {
                        // Ventas diarias
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

        private async Task<ReportData> GenerateProductsReport(
            DateTime startDate, DateTime endDate, string connectionString, ILambdaContext context)
        {
            var reportData = new ReportData
            {
                Title = "Reporte de Productos e Inventario",
                Period = $"{startDate:dd/MM/yyyy} - {endDate:dd/MM/yyyy}"
            };

            // ✅ NOMBRE CORRECTO: ECommerceGRPCProducts (NO ECommerceProducts)
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

            using (var connection = new SqlConnection(connectionString))
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

        private async Task<ReportData> GenerateOrdersReport(
            DateTime startDate, DateTime endDate, string connectionString, ILambdaContext context)
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

            using (var connection = new SqlConnection(connectionString))
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

        // =============================================================
        // PDF, S3, HELPERS - TODO SIN CAMBIOS (código original exacto)
        // =============================================================

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

            var downloadUrl = _s3Client.GetPreSignedURL(urlRequest);
            context.Logger.LogInformation($"Download URL generada (interna a docker): {downloadUrl}");

            // Reemplazar endpoint interno con externo
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