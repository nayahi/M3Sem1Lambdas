#Requires -Version 7

<#
.SYNOPSIS
    Configura la infraestructura de seguridad para Semana 4
.DESCRIPTION
    1. Crea tabla AuditLog en SQL Server (ECommerceOrders)
    2. Crea secretos en Secrets Manager (LocalStack)
    3. Verifica que Keycloak esté corriendo
    4. Obtiene un token de prueba
.NOTES
    Ejecutar DESPUÉS de docker-compose up -d (con Keycloak agregado)
    y ANTES de Deploy-All-Lambdas.ps1
#>

$ErrorActionPreference = "Stop"
$ContainerName = "localstack-aws"
$SqlContainer = "sqlserver"

Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     SETUP SEGURIDAD - SEMANA 4                              ║" -ForegroundColor Cyan
Write-Host "║     AuditLog + Secrets Manager + Keycloak                   ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. CREAR TABLA AUDITLOG EN SQL SERVER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[1/4] 📋 Creando tabla AuditLog en SQL Server..." -ForegroundColor Yellow

$auditLogSql = @"
USE ECommerceOrders;
GO

-- Crear tabla si no existe
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'AuditLog')
BEGIN
    CREATE TABLE dbo.AuditLog (
        Id              INT IDENTITY(1,1) PRIMARY KEY,
        Action          NVARCHAR(100)   NOT NULL,
        UserId          NVARCHAR(200)   NOT NULL,
        ResourceType    NVARCHAR(100)   NOT NULL,
        Details         NVARCHAR(MAX)   NULL,
        Hash            NVARCHAR(64)    NOT NULL,
        PreviousHash    NVARCHAR(64)    NOT NULL,
        CreatedAt       DATETIME2       NOT NULL DEFAULT GETUTCDATE()
    );

    -- Índices para consultas frecuentes
    CREATE INDEX IX_AuditLog_CreatedAt ON dbo.AuditLog (CreatedAt DESC);
    CREATE INDEX IX_AuditLog_UserId ON dbo.AuditLog (UserId);
    CREATE INDEX IX_AuditLog_Action ON dbo.AuditLog (Action);

    PRINT 'Tabla AuditLog creada exitosamente';
END
ELSE
BEGIN
    PRINT 'Tabla AuditLog ya existe';
END
GO

-- SEGURIDAD: Denegar DELETE y UPDATE en AuditLog
-- Esto hace que los logs sean INMUTABLES
-- NOTA: En producción, crear un usuario app específico
-- y aplicar el DENY a ese usuario, no a sa.
-- Para el demo, solo documentamos el concepto.
PRINT 'NOTA: En producción, ejecutar:';
PRINT '  DENY DELETE, UPDATE ON dbo.AuditLog TO [app_user]';
PRINT 'Esto garantiza inmutabilidad de los audit logs.';
GO
"@

# Escribir SQL a archivo temporal y ejecutar
$sqlFile = "/tmp/create_auditlog.sql"
$auditLogSql | docker exec -i $SqlContainer /bin/bash -c "cat > $sqlFile"

docker exec $SqlContainer /opt/mssql-tools18/bin/sqlcmd `
    -S localhost -U sa -P "Password123!" `
    -C -i $sqlFile 2>&1 | ForEach-Object {
        if ($_ -match "creada exitosamente|ya existe") {
            Write-Host "  ✅ $_" -ForegroundColor Green
        } elseif ($_ -match "NOTA:|DENY") {
            Write-Host "  ℹ️ $_" -ForegroundColor Cyan
        }
    }

Write-Host "  ✅ Tabla AuditLog configurada" -ForegroundColor Green

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. CREAR SECRETOS EN SECRETS MANAGER (LOCALSTACK)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[2/4] 🔐 Creando secretos en Secrets Manager..." -ForegroundColor Yellow

# Secreto: Connection string de SQL Server
$sqlConnectionString = "Server=sqlserver,1433;User Id=sa;Password=Password123!;TrustServerCertificate=True;"

# Intentar crear (o actualizar si ya existe)
$createResult = docker exec $ContainerName awslocal secretsmanager create-secret `
    --name "ecommerce/sql-connection" `
    --description "SQL Server connection string para microservicios" `
    --secret-string $sqlConnectionString 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ Secreto creado: ecommerce/sql-connection" -ForegroundColor Green
} else {
    # Ya existe, actualizar
    docker exec $ContainerName awslocal secretsmanager put-secret-value `
        --secret-id "ecommerce/sql-connection" `
        --secret-string $sqlConnectionString 2>&1 | Out-Null
    Write-Host "  ✅ Secreto actualizado: ecommerce/sql-connection" -ForegroundColor Green
}

# Secreto: Credenciales de Redis
$redisSecret = '{"endpoint":"redis:6379","password":""}'
$createRedis = docker exec $ContainerName awslocal secretsmanager create-secret `
    --name "ecommerce/redis-config" `
    --description "Configuración de Redis cache" `
    --secret-string $redisSecret 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ Secreto creado: ecommerce/redis-config" -ForegroundColor Green
} else {
    docker exec $ContainerName awslocal secretsmanager put-secret-value `
        --secret-id "ecommerce/redis-config" `
        --secret-string $redisSecret 2>&1 | Out-Null
    Write-Host "  ✅ Secreto actualizado: ecommerce/redis-config" -ForegroundColor Green
}

# Secreto: Credenciales de Keycloak (Client Credentials)
$keycloakSecret = '{"client_id":"reports-service","client_secret":"reports-secret-2026","token_url":"http://keycloak:8080/realms/ecommerce/protocol/openid-connect/token"}'
$createKc = docker exec $ContainerName awslocal secretsmanager create-secret `
    --name "ecommerce/keycloak-client" `
    --description "Credenciales del cliente reports-service en Keycloak" `
    --secret-string $keycloakSecret 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ Secreto creado: ecommerce/keycloak-client" -ForegroundColor Green
} else {
    docker exec $ContainerName awslocal secretsmanager put-secret-value `
        --secret-id "ecommerce/keycloak-client" `
        --secret-string $keycloakSecret 2>&1 | Out-Null
    Write-Host "  ✅ Secreto actualizado: ecommerce/keycloak-client" -ForegroundColor Green
}

# Listar todos los secretos
Write-Host "`n  📋 Secretos en Secrets Manager:" -ForegroundColor Cyan
docker exec $ContainerName awslocal secretsmanager list-secrets `
    --query "SecretList[].Name" --output table

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. VERIFICAR KEYCLOAK
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[3/4] 🔑 Verificando Keycloak..." -ForegroundColor Yellow

$maxRetries = 10
$retryCount = 0
$keycloakReady = $false

while ($retryCount -lt $maxRetries -and -not $keycloakReady) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:8080/realms/ecommerce" `
            -UseBasicParsing -TimeoutSec 5 2>&1
        if ($response.StatusCode -eq 200) {
            $keycloakReady = $true
            Write-Host "  ✅ Keycloak realm 'ecommerce' disponible" -ForegroundColor Green
        }
    } catch {
        $retryCount++
        Write-Host "  ⏳ Esperando Keycloak ($retryCount/$maxRetries)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

if (-not $keycloakReady) {
    Write-Host "  ⚠️ Keycloak no responde. Verificar:" -ForegroundColor Red
    Write-Host "    1. ¿Está keycloak en docker-compose?" -ForegroundColor Red
    Write-Host "    2. docker logs keycloak" -ForegroundColor Red
    Write-Host "    3. Keycloak tarda 30-60 seg en iniciar" -ForegroundColor Red
    Write-Host "  Continuando sin Keycloak..." -ForegroundColor Yellow
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. OBTENER TOKEN DE PRUEBA
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[4/4] 🎫 Obteniendo token de prueba..." -ForegroundColor Yellow

if ($keycloakReady) {
    try {
        $tokenResponse = Invoke-RestMethod -Uri "http://localhost:8080/realms/ecommerce/protocol/openid-connect/token" `
            -Method Post `
            -ContentType "application/x-www-form-urlencoded" `
            -Body @{
                grant_type    = "client_credentials"
                client_id     = "reports-service"
                client_secret = "reports-secret-2026"
            }
        
        $token = $tokenResponse.access_token
        $expiresIn = $tokenResponse.expires_in
        
        Write-Host "  ✅ Token obtenido exitosamente" -ForegroundColor Green
        Write-Host "  ⏰ Expira en: $expiresIn segundos" -ForegroundColor Cyan
        Write-Host "  🔑 Token (primeros 50 chars): $($token.Substring(0, [Math]::Min(50, $token.Length)))..." -ForegroundColor Cyan
        
        # Guardar token en variable para uso en tests
        $env:KEYCLOAK_TOKEN = $token
        Write-Host "`n  💡 Token guardado en `$env:KEYCLOAK_TOKEN para uso en tests" -ForegroundColor Yellow
    } catch {
        Write-Host "  ⚠️ No se pudo obtener token: $_" -ForegroundColor Red
    }
} else {
    Write-Host "  ⏭️ Saltando (Keycloak no disponible)" -ForegroundColor Yellow
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# RESUMEN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     ✅ SETUP SEMANA 4 COMPLETADO                            ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n📋 Resumen:" -ForegroundColor Yellow
Write-Host "  ✅ AuditLog table en ECommerceOrders" -ForegroundColor White
Write-Host "  ✅ 3 secretos en Secrets Manager:" -ForegroundColor White
Write-Host "     - ecommerce/sql-connection" -ForegroundColor Cyan
Write-Host "     - ecommerce/redis-config" -ForegroundColor Cyan
Write-Host "     - ecommerce/keycloak-client" -ForegroundColor Cyan
if ($keycloakReady) {
    Write-Host "  ✅ Keycloak realm 'ecommerce' activo en :8080" -ForegroundColor White
    Write-Host "     - Client: reports-service / reports-secret-2026" -ForegroundColor Cyan
    Write-Host "     - Users: docente/docente123, estudiante/estudiante123" -ForegroundColor Cyan
} else {
    Write-Host "  ⚠️ Keycloak pendiente de verificación" -ForegroundColor Yellow
}

Write-Host "`n🚀 Siguiente paso:" -ForegroundColor Yellow
Write-Host "  1. Compilar Reports.Lambda con nuevo Function.cs y .csproj" -ForegroundColor White
Write-Host "  2. Ejecutar Deploy-All-Lambdas.ps1 (ya actualizado con env vars de Semana 4)" -ForegroundColor White
Write-Host "  3. Ejecutar Test-Reports-Security.ps1 para verificar" -ForegroundColor White
