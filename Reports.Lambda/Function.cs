using Amazon.Lambda.Core;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.S3;
using Amazon.S3.Model;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
using Microsoft.Data.SqlClient;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;
using StackExchange.Redis;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

// Aliases para evitar ambigüedad QuestPDF vs System
using QuestDocument = QuestPDF.Fluent.Document;
using QuestContainer = QuestPDF.Infrastructure.IContainer;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace Reports.Lambda
{
    /// <summary>
    /// Lambda function para generación de reportes on-demand.
    /// 
    /// Semana 1: Handler API Gateway + SQL + QuestPDF + S3
    /// Semana 2: Polly (resiliencia)
    /// Semana 3: Redis Cache-Aside
    /// Semana 4: Secrets Manager + Audit Log (hash chain) + JWT validation
    /// 
    /// Event Source: API Gateway (LocalStack)
    /// Database: SQL Server (múltiples bases de datos)
    /// Cache: Redis (Cache-Aside pattern)
    /// Secrets: AWS Secrets Manager (LocalStack)
    /// Audit: SQL Server (ECommerceOrders.dbo.AuditLog)
    /// Output: S3 (bucket: reports-generated)
    /// </summary>
    public class Function
    {
        // --- Campos existentes (Semana 1) ---
        private readonly IAmazonS3 _s3Client;
        private readonly string _reportsBucket;

        // --- Semana 3: Redis ---
        private ConnectionMultiplexer? _redis;
        private IDatabase? _redisDb;
        private readonly string _redisEndpoint;
        private readonly int _cacheTtlSeconds;

        // --- Semana 4: Secrets Manager ---
        private readonly IAmazonSecretsManager _secretsClient;
        private readonly string _secretName;
        private string? _cachedConnectionString;

        // --- Semana 4: JWT ---
        private readonly string _expectedIssuer;

        /// <summary>
        /// Constructor por defecto - usado por Lambda runtime.
        /// REGLA: Constructor debe ser instantáneo. NO hacer I/O aquí.
        /// </summary>
        public Function()
        {
            // QuestPDF License
            QuestPDF.Settings.License = LicenseType.Community;

            // S3 (Semana 1)
            var s3Endpoint = Environment.GetEnvironmentVariable("S3_ENDPOINT")
                ?? "http://localstack:4566";
            var s3Config = new AmazonS3Config
            {
                ServiceURL = s3Endpoint,
                ForcePathStyle = true
            };
            _s3Client = new AmazonS3Client(s3Config);
            _reportsBucket = Environment.GetEnvironmentVariable("REPORTS_BUCKET")
                ?? "reports-generated";

            // Redis (Semana 3) - solo guardamos endpoint, conexión lazy
            _redisEndpoint = Environment.GetEnvironmentVariable("REDIS_ENDPOINT")
                ?? "redis:6379";
            _cacheTtlSeconds = int.Parse(
                Environment.GetEnvironmentVariable("CACHE_TTL_SECONDS") ?? "600");

            // Secrets Manager (Semana 4)
            var smEndpoint = Environment.GetEnvironmentVariable("SECRETS_ENDPOINT")
                ?? "http://localstack:4566";
            var smConfig = new AmazonSecretsManagerConfig
            {
                ServiceURL = smEndpoint
            };
            _secretsClient = new AmazonSecretsManagerClient(smConfig);
            _secretName = Environment.GetEnvironmentVariable("SQL_SECRET_NAME")
                ?? "ecommerce/sql-connection";

            // JWT (Semana 4)
            _expectedIssuer = Environment.GetEnvironmentVariable("JWT_ISSUER")
                ?? "http://keycloak:8080/realms/ecommerce";
        }

        // =====================================================================
        // SEMANA 4 - SECRETS MANAGER: Obtener connection string de forma segura
        // =====================================================================

        /// <summary>
        /// Obtiene el connection string de Secrets Manager con fallback.
        /// Cachea en memoria para evitar llamadas repetidas (warm Lambda).
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
                // Intentar obtener de Secrets Manager
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

                _cachedConnectionString = Environment.GetEnvironmentVariable("SQL_CONNECTION_STRING")
                    ?? "Server=sqlserver,1433;User Id=sa;Password=Password123!;TrustServerCertificate=True;";
                return _cachedConnectionString;
            }
        }

        // =====================================================================
        // SEMANA 4 - JWT VALIDATION: Verificar token de autorización
        // =====================================================================

        /// <summary>
        /// Valida el JWT del header Authorization.
        /// NOTA EDUCATIVA: En producción usar Microsoft.IdentityModel.Tokens
        /// con verificación criptográfica completa. Aquí decodificamos el payload
        /// para demostrar la estructura de un JWT y validaciones básicas.
        /// </summary>
        private (bool isValid, string userId, string? error) ValidateJwtToken(
            APIGatewayProxyRequest request, ILambdaContext context)
        {
            // 1. Verificar header Authorization
            var authHeader = request.Headers?
                .FirstOrDefault(h => h.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase))
                .Value;

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

                // 5. Validar issuer (claim "iss")
                if (payload.TryGetValue("iss", out var issElement))
                {
                    var issuer = issElement.GetString();
                    if (issuer != _expectedIssuer)
                    {
                        context.Logger.LogWarning(
                            $"⚠️ Issuer no coincide. Esperado: {_expectedIssuer}, Recibido: {issuer}");
                        // En producción: return (false, ...). En demo, solo logueamos.
                    }
                }

                // 6. Extraer identidad del usuario/servicio
                var userId = "unknown";
                if (payload.TryGetValue("preferred_username", out var userElement))
                    userId = userElement.GetString() ?? "unknown";
                else if (payload.TryGetValue("client_id", out var clientElement))
                    userId = clientElement.GetString() ?? "unknown";
                else if (payload.TryGetValue("sub", out var subElement))
                    userId = subElement.GetString() ?? "unknown";

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
        /// Base64Url usa '-' en lugar de '+' y '_' en lugar de '/'.
        /// </summary>
        private static string DecodeBase64Url(string base64Url)
        {
            var base64 = base64Url.Replace('-', '+').Replace('_', '/');
            switch (base64.Length % 4)
            {
                case 2: base64 += "=="; break;
                case 3: base64 += "="; break;
            }
            var bytes = Convert.FromBase64String(base64);
            return Encoding.UTF8.GetString(bytes);
        }

        // =====================================================================
        // SEMANA 4 - AUDIT LOG: Registro inmutable con hash chain
        // =====================================================================

        /// <summary>
        /// Escribe una entrada de auditoría con hash chain inmutable.
        /// Cada entrada incluye el hash del registro anterior, formando una cadena
        /// que permite detectar si alguien alteró registros pasados.
        /// 
        /// Hash = SHA256(previousHash + "|" + action + "|" + userId + "|" + timestamp + "|" + details)
        /// Primera entrada usa "genesis" como previousHash.
        /// </summary>
        private async Task WriteAuditLogAsync(
            string action, string userId, string reportType,
            string details, string connectionString, ILambdaContext context)
        {
            try
            {
                using var connection = new SqlConnection(connectionString);
                await connection.OpenAsync();

                // 1. Obtener hash del último registro (para la cadena)
                var previousHash = "genesis";
                var getLastHashQuery = @"
                    SELECT TOP 1 Hash 
                    FROM ECommerceOrders.dbo.AuditLog 
                    ORDER BY Id DESC";

                using (var cmd = new SqlCommand(getLastHashQuery, connection))
                {
                    var result = await cmd.ExecuteScalarAsync();
                    if (result != null && result != DBNull.Value)
                    {
                        previousHash = result.ToString()!;
                    }
                }

                // 2. Construir datos para hash
                var timestamp = DateTime.UtcNow;
                var dataToHash = $"{previousHash}|{action}|{userId}|{timestamp:O}|{details}";

                // 3. Calcular SHA256
                var hash = ComputeSha256(dataToHash);

                // 4. Insertar registro de auditoría
                var insertQuery = @"
                    INSERT INTO ECommerceOrders.dbo.AuditLog 
                        (Action, UserId, ResourceType, Details, Hash, PreviousHash, CreatedAt)
                    VALUES 
                        (@Action, @UserId, @ResourceType, @Details, @Hash, @PreviousHash, @CreatedAt)";

                using (var cmd = new SqlCommand(insertQuery, connection))
                {
                    cmd.Parameters.AddWithValue("@Action", action);
                    cmd.Parameters.AddWithValue("@UserId", userId);
                    cmd.Parameters.AddWithValue("@ResourceType", reportType);
                    cmd.Parameters.AddWithValue("@Details", details);
                    cmd.Parameters.AddWithValue("@Hash", hash);
                    cmd.Parameters.AddWithValue("@PreviousHash", previousHash);
                    cmd.Parameters.AddWithValue("@CreatedAt", timestamp);

                    await cmd.ExecuteNonQueryAsync();
                }

                context.Logger.LogInformation(
                    $"📋 Audit log escrito: {action} por {userId} | Hash: {hash[..12]}...");
            }
            catch (Exception ex)
            {
                // Audit log NO debe romper el flujo principal
                context.Logger.LogWarning($"⚠️ Error escribiendo audit log: {ex.Message}");
            }
        }

        /// <summary>
        /// Calcula SHA256 de un string. Retorna hex string.
        /// </summary>
        private static string ComputeSha256(string input)
        {
            var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(input));
            return Convert.ToHexString(bytes).ToLowerInvariant();
        }

        // =====================================================================
        // SEMANA 3 - REDIS: Conexión lazy
        // =====================================================================

        private void EnsureRedisConnection(ILambdaContext context)
        {
            if (_redisDb != null) return;
            try
            {
                var options = ConfigurationOptions.Parse(_redisEndpoint);
                options.ConnectTimeout = 3000;
                options.SyncTimeout = 2000;
                options.AbortOnConnectFail = false;

                _redis = ConnectionMultiplexer.Connect(options);
                _redisDb = _redis.GetDatabase();
                context.Logger.LogInformation($"✅ Redis conectado: {_redisEndpoint}");
            }
            catch (Exception ex)
            {
                context.Logger.LogWarning($"⚠️ Redis no disponible: {ex.Message}. Continuando sin caché.");
                _redisDb = null;
            }
        }

        // =====================================================================
        // HANDLER PRINCIPAL
        // =====================================================================

        /// <summary>
        /// Handler principal de la función Lambda.
        /// Flujo Semana 4:
        ///   1. Validar JWT → saber QUIÉN pide el reporte
        ///   2. Obtener connection string de Secrets Manager → NO hardcodear secretos
        ///   3. Verificar Redis cache (Semana 3)
        ///   4. Generar reporte si no está en caché
        ///   5. Escribir Audit Log con hash chain → trazabilidad inmutable
        ///   6. Retornar resultado
        /// </summary>
        public async Task<APIGatewayProxyResponse> FunctionHandler(
            APIGatewayProxyRequest request,
            ILambdaContext context)
        {
            try
            {
                context.Logger.LogInformation("=== Reports Lambda - Semana 4: Seguridad ===");

                // ─── PASO 1: Validar JWT (Semana 4) ───
                var (isValid, userId, jwtError) = ValidateJwtToken(request, context);

                if (!isValid)
                {
                    context.Logger.LogWarning($"🚫 Acceso denegado: {jwtError}");

                    // Auditar intento fallido
                    var fallbackCs = Environment.GetEnvironmentVariable("SQL_CONNECTION_STRING")
                        ?? "Server=sqlserver,1433;User Id=sa;Password=Password123!;TrustServerCertificate=True;";
                    await WriteAuditLogAsync(
                        "REPORT_ACCESS_DENIED", "anonymous", "N/A",
                        $"JWT inválido: {jwtError}", fallbackCs, context);

                    return CreateResponse(401, new
                    {
                        error = "No autorizado",
                        detail = jwtError
                    });
                }

                // ─── PASO 2: Obtener connection string de Secrets Manager (Semana 4) ───
                var connectionString = await GetConnectionStringAsync(context);

                // ─── Parsear parámetros de query string ───
                var reportType = request.QueryStringParameters?
                    .GetValueOrDefault("type", "sales") ?? "sales";
                var startDateStr = request.QueryStringParameters?
                    .GetValueOrDefault("startDate", "2024-01-01") ?? "2024-01-01";
                var endDateStr = request.QueryStringParameters?
                    .GetValueOrDefault("endDate", "2025-12-31") ?? "2025-12-31";

                if (!DateTime.TryParse(startDateStr, out var start) ||
                    !DateTime.TryParse(endDateStr, out var end))
                {
                    return CreateResponse(400, new
                    {
                        error = "Formato de fecha inválido. Usar: yyyy-MM-dd"
                    });
                }

                if (start > end)
                {
                    return CreateResponse(400, new
                    {
                        error = "La fecha de inicio debe ser menor a la fecha fin"
                    });
                }

                context.Logger.LogInformation(
                    $"📊 Reporte: {reportType} | Período: {startDateStr} - {endDateStr} | Usuario: {userId}");

                // ─── PASO 3: Verificar Redis cache (Semana 3) ───
                EnsureRedisConnection(context);
                var cacheKey = $"report:{reportType}:{startDateStr}:{endDateStr}";
                ReportData? reportData = null;

                if (_redisDb != null)
                {
                    try
                    {
                        var cached = await _redisDb.StringGetAsync(cacheKey);
                        if (cached.HasValue)
                        {
                            reportData = JsonSerializer.Deserialize<ReportData>(cached!);
                            context.Logger.LogInformation($"⚡ CACHE HIT: {cacheKey}");
                        }
                        else
                        {
                            context.Logger.LogInformation($"💨 CACHE MISS: {cacheKey}");
                        }
                    }
                    catch (Exception ex)
                    {
                        context.Logger.LogWarning($"⚠️ Error leyendo caché: {ex.Message}");
                    }
                }

                // ─── PASO 4: Generar datos si no hay caché ───
                if (reportData == null)
                {
                    reportData = reportType.ToLower() switch
                    {
                        "sales" => await GenerateSalesReport(start, end, connectionString, context),
                        "products" => await GenerateProductsReport(start, end, connectionString, context),
                        "orders" => await GenerateOrdersReport(start, end, connectionString, context),
                        _ => throw new ArgumentException($"Tipo de reporte no soportado: {reportType}")
                    };

                    // Guardar en caché
                    if (_redisDb != null)
                    {
                        try
                        {
                            var json = JsonSerializer.Serialize(reportData);
                            await _redisDb.StringSetAsync(cacheKey, json,
                                TimeSpan.FromSeconds(_cacheTtlSeconds));
                            context.Logger.LogInformation(
                                $"💾 Guardado en caché: {cacheKey} (TTL: {_cacheTtlSeconds}s)");
                        }
                        catch (Exception ex)
                        {
                            context.Logger.LogWarning($"⚠️ Error guardando caché: {ex.Message}");
                        }
                    }
                }

                // ─── PASO 5: Generar PDF ───
                var pdfBytes = GeneratePDF(reportData, reportType, start, end, context);

                // ─── PASO 6: Subir a S3 ───
                var reportUrl = await UploadToS3AndGetUrl(pdfBytes, reportType, context);

                // ─── PASO 7: Escribir Audit Log (Semana 4) ───
                await WriteAuditLogAsync(
                    "REPORT_GENERATED",
                    userId,
                    reportType,
                    $"Período: {startDateStr} - {endDateStr} | Tamaño: {pdfBytes.Length} bytes",
                    connectionString,
                    context);

                return CreateResponse(200, new
                {
                    success = true,
                    reportType,
                    generatedAt = DateTime.UtcNow,
                    generatedBy = userId,
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

        // =====================================================================
        // GENERACIÓN DE REPORTES (SQL) - Usa connection string de Secrets Manager
        // =====================================================================

        private async Task<ReportData> GenerateSalesReport(
            DateTime startDate, DateTime endDate, string connectionString, ILambdaContext context)
        {
            var reportData = new ReportData
            {
                Title = "Reporte de Ventas",
                Period = $"{startDate:dd/MM/yyyy} - {endDate:dd/MM/yyyy}"
            };

            var query = @"
                SELECT 
                    CAST(o.CreatedAt AS DATE) as Fecha,
                    COUNT(DISTINCT o.Id) as TotalOrdenes,
                    COUNT(DISTINCT o.UserId) as ClientesUnicos,
                    SUM(o.TotalAmount) as VentasTotal,
                    AVG(o.TotalAmount) as TicketPromedio
                FROM ECommerceOrders.dbo.Orders o
                WHERE o.CreatedAt >= @StartDate AND o.CreatedAt <= @EndDate
                GROUP BY CAST(o.CreatedAt AS DATE)
                ORDER BY Fecha;

                SELECT TOP 10
                    oi.ProductName,
                    SUM(oi.Quantity) as CantidadVendida,
                    SUM(oi.Quantity * oi.UnitPrice) as IngresoTotal
                FROM ECommerceOrders.dbo.OrderItems oi
                INNER JOIN ECommerceOrders.dbo.Orders o ON oi.OrderId = o.Id
                WHERE o.CreatedAt >= @StartDate AND o.CreatedAt <= @EndDate
                GROUP BY oi.ProductName
                ORDER BY IngresoTotal DESC;

                SELECT 
                    p.PaymentMethod as Metodo,
                    COUNT(*) as Transacciones,
                    SUM(p.Amount) as MontoTotal,
                    AVG(p.Amount) as MontoPromedio
                FROM ECommercePayments.dbo.Payments p
                WHERE p.CreatedAt >= @StartDate AND p.CreatedAt <= @EndDate
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
                                ["Fecha"] = reader.GetDateTime(0).ToString("yyyy-MM-dd"),
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

            context.Logger.LogInformation($"Datos obtenidos: {reportData.Sections.Count} secciones");
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

            var query = @"
                SELECT 
                    Category as Categoría,
                    COUNT(*) as TotalProductos,
                    AVG(Price) as PrecioPromedio,
                    SUM(Stock) as StockTotal
                FROM ECommerceProducts.dbo.Products
                WHERE IsActive = 1
                GROUP BY Category
                ORDER BY TotalProductos DESC;

                SELECT 
                    Name as Producto,
                    Category as Categoría,
                    Stock,
                    Price as Precio
                FROM ECommerceProducts.dbo.Products
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
                        var byCategory = new List<Dictionary<string, object>>();
                        while (await reader.ReadAsync())
                        {
                            byCategory.Add(new Dictionary<string, object>
                            {
                                ["Categoría"] = reader.GetString(0),
                                ["Productos"] = reader.GetInt32(1).ToString(),
                                ["Precio Promedio"] = $"${reader.GetDecimal(2):N2}",
                                ["Stock Total"] = reader.GetInt32(3).ToString()
                            });
                        }
                        reportData.Sections.Add("Productos por Categoría", byCategory);

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
                SELECT 
                    Status as Estado,
                    COUNT(*) as TotalÓrdenes,
                    SUM(TotalAmount) as MontoTotal
                FROM ECommerceOrders.dbo.Orders
                WHERE CreatedAt >= @StartDate AND CreatedAt <= @EndDate
                GROUP BY Status
                ORDER BY TotalÓrdenes DESC;

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

        // =====================================================================
        // PDF GENERATION (QuestPDF) - Sin cambios respecto a Semana 3
        // =====================================================================

        private byte[] GeneratePDF(ReportData data, string reportType,
            DateTime startDate, DateTime endDate, ILambdaContext context)
        {
            context.Logger.LogInformation("Generando PDF con QuestPDF");

            var document = QuestDocument.Create(container =>
            {
                container.Page(page =>
                {
                    page.Size(PageSizes.Letter);
                    page.Margin(2, Unit.Centimetre);
                    page.PageColor(Colors.White);
                    page.DefaultTextStyle(x => x.FontSize(11));

                    page.Header().Element(ComposeHeader);
                    page.Content().Element(c => ComposeContent(c, data));
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

            void ComposeHeader(QuestContainer container)
            {
                container.Row(row =>
                {
                    row.RelativeItem().Column(column =>
                    {
                        column.Item().Text(data.Title)
                            .FontSize(20).SemiBold().FontColor(Colors.Blue.Darken2);
                        column.Item().Text($"Período: {data.Period}").FontSize(12);
                        column.Item().Text($"Tipo: {reportType}")
                            .FontSize(10).FontColor(Colors.Grey.Medium);
                    });
                });
            }

            void ComposeContent(QuestContainer container, ReportData reportData)
            {
                container.Column(outerColumn =>
                {
                    foreach (var section in reportData.Sections)
                    {
                        outerColumn.Item().PaddingTop(15).Text(section.Key)
                            .FontSize(14).SemiBold().FontColor(Colors.Blue.Darken1);
                        outerColumn.Item().LineHorizontal(1).LineColor(Colors.Grey.Lighten2);

                        if (section.Value.Count == 0)
                        {
                            outerColumn.Item().PaddingTop(5).Text("Sin datos para este período")
                                .FontSize(10).Italic().FontColor(Colors.Grey.Medium);
                            continue;
                        }

                        outerColumn.Item().PaddingTop(5).Table(table =>
                        {
                            var columns = section.Value[0].Keys.ToList();
                            table.ColumnsDefinition(cd =>
                            {
                                foreach (var _ in columns) cd.RelativeColumn();
                            });

                            // Headers
                            foreach (var col in columns)
                            {
                                table.Cell().Background(Colors.Blue.Darken2).Padding(5)
                                    .Text(col).FontColor(Colors.White).FontSize(9).SemiBold();
                            }

                            // Rows
                            var rowIndex = 0;
                            foreach (var row in section.Value)
                            {
                                var bgColor = rowIndex % 2 == 0
                                    ? Colors.White : Colors.Grey.Lighten4;
                                foreach (var col in columns)
                                {
                                    table.Cell().Background(bgColor).Padding(4)
                                        .Text(row[col]?.ToString() ?? "").FontSize(9);
                                }
                                rowIndex++;
                            }
                        });
                    }
                });
            }
        }

        // =====================================================================
        // S3 UPLOAD - Sin cambios
        // =====================================================================

        private async Task<string> UploadToS3AndGetUrl(byte[] pdfBytes, string reportType,
            ILambdaContext context)
        {
            var key = $"reports/{DateTime.UtcNow:yyyy/MM}/{reportType}_{DateTime.UtcNow:yyyyMMdd_HHmmss}.pdf";

            context.Logger.LogInformation($"Subiendo PDF a S3: {_reportsBucket}/{key}");

            await _s3Client.PutObjectAsync(new PutObjectRequest
            {
                BucketName = _reportsBucket,
                Key = key,
                InputStream = new MemoryStream(pdfBytes),
                ContentType = "application/pdf"
            });

            var urlRequest = new GetPreSignedUrlRequest
            {
                BucketName = _reportsBucket,
                Key = key,
                Expires = DateTime.UtcNow.AddHours(1),
                Protocol = Protocol.HTTP
            };

            var preSignedUrl = _s3Client.GetPreSignedURL(urlRequest);

            // Fix para LocalStack: reemplazar hostname interno
            var fixedUrl = preSignedUrl.Replace("localstack", "localhost");

            context.Logger.LogInformation($"✅ URL generada (válida 1 hora)");
            return fixedUrl;
        }

        // =====================================================================
        // HELPERS
        // =====================================================================

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

    /// <summary>
    /// Modelo para datos del reporte (serializable para Redis cache).
    /// </summary>
    public class ReportData
    {
        public string Title { get; set; } = "";
        public string Period { get; set; } = "";
        public Dictionary<string, List<Dictionary<string, object>>> Sections { get; set; } = new();
    }
}