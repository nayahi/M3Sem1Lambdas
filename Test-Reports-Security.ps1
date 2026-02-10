#Requires -Version 7

<#
.SYNOPSIS
    Pruebas de seguridad para Reports.Lambda Semana 4
.DESCRIPTION
    Test 1: Llamada SIN token → debe retornar 401
    Test 2: Llamada CON token válido → debe retornar 200
    Test 3: Verificar que Secrets Manager fue usado (logs)
    Test 4: Verificar Audit Log en SQL Server (hash chain)
    Test 5: Verificar integridad del hash chain
#>

param(
    [ValidateSet("All", "JWT", "SecretsManager", "AuditLog")]
    [string]$Test = "All"
)

$ErrorActionPreference = "Stop"
$ContainerName = "localstack-aws"
$SqlContainer = "sqlserver"

Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     TEST SEGURIDAD - SEMANA 4                               ║" -ForegroundColor Cyan
Write-Host "║     JWT + Secrets Manager + Audit Log                       ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Obtener API Gateway ID
$apiId = docker exec $ContainerName awslocal apigateway get-rest-apis `
    --query "items[?name=='ReportsAPI'].id" --output text
$apiId = $apiId.Trim()

if ([string]::IsNullOrWhiteSpace($apiId)) {
    Write-Host "❌ No se encontró ReportsAPI. Ejecutar Deploy-All-Lambdas.ps1 primero." -ForegroundColor Red
    exit 1
}

$apiUrl = "http://localhost:4566/restapis/$apiId/prod/_user_request_/reports"
Write-Host "`n📍 API URL: $apiUrl" -ForegroundColor Cyan

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FUNCIÓN AUXILIAR: Obtener token de Keycloak
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Get-KeycloakToken {
    param(
        [string]$ClientId = "reports-service",
        [string]$ClientSecret = "reports-secret-2026"
    )
    
    try {
        $tokenResponse = Invoke-RestMethod `
            -Uri "http://localhost:8080/realms/ecommerce/protocol/openid-connect/token" `
            -Method Post `
            -ContentType "application/x-www-form-urlencoded" `
            -Body @{
                grant_type    = "client_credentials"
                client_id     = $ClientId
                client_secret = $ClientSecret
            }
        return $tokenResponse.access_token
    } catch {
        Write-Host "  ⚠️ No se pudo obtener token de Keycloak: $_" -ForegroundColor Red
        return $null
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 1: Llamada SIN token → 401
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if ($Test -eq "All" -or $Test -eq "JWT") {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "TEST 1: 🚫 Llamada SIN token (debe dar 401)" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow

    $testUrl = "${apiUrl}?type=sales&startDate=2024-01-01&endDate=2025-12-31"
    
    try {
        $response = Invoke-WebRequest -Uri $testUrl -UseBasicParsing -ErrorAction SilentlyContinue
        $body = $response.Content | ConvertFrom-Json
        
        if ($response.StatusCode -eq 200) {
            $innerBody = $body.body | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($innerBody -and $innerBody.error -eq "No autorizado") {
                Write-Host "  ✅ TEST 1 PASSED: Retornó 401 (No autorizado)" -ForegroundColor Green
                Write-Host "  📄 Detalle: $($innerBody.detail)" -ForegroundColor Cyan
            } elseif ($body.statusCode -eq 401) {
                Write-Host "  ✅ TEST 1 PASSED: statusCode 401 en body" -ForegroundColor Green
            } else {
                # Lambda proxy integration: check body
                Write-Host "  ⚠️ Response inesperado. StatusCode HTTP: $($response.StatusCode)" -ForegroundColor Yellow
                Write-Host "  Body: $($response.Content.Substring(0, [Math]::Min(300, $response.Content.Length)))" -ForegroundColor Gray
            }
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            Write-Host "  ✅ TEST 1 PASSED: HTTP $statusCode" -ForegroundColor Green
        } else {
            Write-Host "  ℹ️ Respuesta: $statusCode - Verificar en logs" -ForegroundColor Yellow
        }
    }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # TEST 2: Llamada CON token válido → 200
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "TEST 2: ✅ Llamada CON token (debe dar 200)" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow

    Write-Host "  🔑 Obteniendo token de Keycloak..." -ForegroundColor Cyan
    $token = Get-KeycloakToken
    
    if ($token) {
        Write-Host "  ✅ Token obtenido (${($token.Length)} chars)" -ForegroundColor Green
        
        try {
            $headers = @{ "Authorization" = "Bearer $token" }
            $response = Invoke-WebRequest -Uri $testUrl -Headers $headers -UseBasicParsing
            $body = $response.Content | ConvertFrom-Json
            
            # API Gateway proxy: body viene envuelto
            $innerBody = $null
            if ($body.body) {
                $innerBody = $body.body | ConvertFrom-Json -ErrorAction SilentlyContinue
            } else {
                $innerBody = $body
            }
            
            if ($innerBody -and $innerBody.success -eq $true) {
                Write-Host "  ✅ TEST 2 PASSED: Reporte generado exitosamente" -ForegroundColor Green
                Write-Host "  📊 Tipo: $($innerBody.reportType)" -ForegroundColor Cyan
                Write-Host "  👤 Generado por: $($innerBody.generatedBy)" -ForegroundColor Cyan
                Write-Host "  📦 Tamaño: $($innerBody.fileSize) bytes" -ForegroundColor Cyan
                Write-Host "  🔗 URL: $($innerBody.downloadUrl.Substring(0, [Math]::Min(80, $innerBody.downloadUrl.Length)))..." -ForegroundColor Gray
            } else {
                Write-Host "  ⚠️ Respuesta inesperada:" -ForegroundColor Yellow
                Write-Host "  $($response.Content.Substring(0, [Math]::Min(300, $response.Content.Length)))" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  ❌ Error: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  ⚠️ No se pudo obtener token. ¿Keycloak está corriendo?" -ForegroundColor Red
        Write-Host "  Verificar: curl http://localhost:8080/realms/ecommerce" -ForegroundColor Yellow
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 3: Verificar Secrets Manager en logs
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if ($Test -eq "All" -or $Test -eq "SecretsManager") {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "TEST 3: 🔐 Verificar Secrets Manager" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow

    # Verificar que el secreto existe
    Write-Host "  📋 Secretos disponibles:" -ForegroundColor Cyan
    docker exec $ContainerName awslocal secretsmanager list-secrets `
        --query "SecretList[].Name" --output table

    # Leer el secreto (para verificar)
    $secretValue = docker exec $ContainerName awslocal secretsmanager get-secret-value `
        --secret-id "ecommerce/sql-connection" `
        --query "SecretString" --output text 2>&1

    if ($LASTEXITCODE -eq 0) {
        # Ocultar password en output
        $maskedValue = $secretValue -replace "Password=.*?;", "Password=***;";
        Write-Host "  ✅ Secreto legible: $maskedValue" -ForegroundColor Green
    } else {
        Write-Host "  ❌ No se pudo leer el secreto" -ForegroundColor Red
    }

    # Verificar logs de Lambda para confirmar uso de SM
    Write-Host "`n  📜 Buscando en logs de Lambda..." -ForegroundColor Cyan
    Start-Sleep -Seconds 3

    $logs = docker exec $ContainerName awslocal logs filter-log-events `
        --log-group-name "/aws/lambda/ReportsGeneratorFunction" `
        --filter-pattern "Secrets Manager" `
        --limit 5 `
        --query "events[].message" --output text 2>&1

    if ($logs -and $logs -match "Secrets Manager") {
        Write-Host "  ✅ TEST 3 PASSED: Lambda está usando Secrets Manager" -ForegroundColor Green
        $logs -split "`n" | ForEach-Object {
            if ($_ -match "Secrets Manager") {
                Write-Host "     $_" -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "  ℹ️ No se encontraron logs de Secrets Manager aún." -ForegroundColor Yellow
        Write-Host "     Ejecutar Test 2 primero para generar logs." -ForegroundColor Yellow
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 4: Verificar Audit Log
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if ($Test -eq "All" -or $Test -eq "AuditLog") {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "TEST 4: 📋 Verificar Audit Log (hash chain)" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow

    $auditQuery = @"
SELECT TOP 10 
    Id, 
    Action, 
    UserId, 
    ResourceType,
    LEFT(Details, 60) as Details,
    LEFT(Hash, 16) as HashPrefix, 
    LEFT(PreviousHash, 16) as PrevHashPrefix,
    CreatedAt
FROM ECommerceOrders.dbo.AuditLog 
ORDER BY Id DESC
"@

    $result = docker exec $SqlContainer /opt/mssql-tools18/bin/sqlcmd `
        -S localhost -U sa -P "Password123!" -C `
        -Q $auditQuery -W 2>&1

    if ($result -match "REPORT_GENERATED|REPORT_ACCESS_DENIED") {
        Write-Host "  ✅ TEST 4 PASSED: Audit logs encontrados" -ForegroundColor Green
        Write-Host "" -ForegroundColor White
        $result | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    } else {
        Write-Host "  ℹ️ No hay audit logs aún. Ejecutar Tests 1 y 2 primero." -ForegroundColor Yellow
        if ($result) {
            $result | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        }
    }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # TEST 5: Verificar integridad del hash chain
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "TEST 5: 🔗 Verificar integridad hash chain" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow

    $chainQuery = @"
SELECT Id, Hash, PreviousHash
FROM ECommerceOrders.dbo.AuditLog 
ORDER BY Id ASC
"@

    $chainResult = docker exec $SqlContainer /opt/mssql-tools18/bin/sqlcmd `
        -S localhost -U sa -P "Password123!" -C `
        -Q $chainQuery -W -h -1 -s "|" 2>&1

    $chainValid = $true
    $previousExpected = "genesis"
    $recordCount = 0

    foreach ($line in $chainResult) {
        if ($line -match "^\s*(\d+)\|(.+)\|(.+)\s*$") {
            $recordCount++
            $id = $Matches[1].Trim()
            $hash = $Matches[2].Trim()
            $prevHash = $Matches[3].Trim()

            if ($prevHash -ne $previousExpected) {
                Write-Host "  ❌ Cadena rota en registro Id=$id" -ForegroundColor Red
                Write-Host "     Esperado PrevHash: $($previousExpected.Substring(0, 16))..." -ForegroundColor Red
                Write-Host "     Encontrado:        $($prevHash.Substring(0, 16))..." -ForegroundColor Red
                $chainValid = $false
                break
            }
            $previousExpected = $hash
        }
    }

    if ($recordCount -gt 0) {
        if ($chainValid) {
            Write-Host "  ✅ TEST 5 PASSED: Hash chain íntegro ($recordCount registros)" -ForegroundColor Green
            Write-Host "  🔗 genesis → hash₁ → hash₂ → ... → hash_$recordCount ✓" -ForegroundColor Cyan
        }
    } else {
        Write-Host "  ℹ️ No hay registros para verificar. Ejecutar Tests 1 y 2 primero." -ForegroundColor Yellow
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# RESUMEN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     TESTS SEMANA 4 COMPLETADOS                              ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n💡 Comandos útiles para inspección manual:" -ForegroundColor Yellow
Write-Host "  # Ver audit logs:" -ForegroundColor Cyan
Write-Host '  docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Password123!" -C -Q "SELECT * FROM ECommerceOrders.dbo.AuditLog ORDER BY Id DESC"' -ForegroundColor Gray
Write-Host "`n  # Ver secretos:" -ForegroundColor Cyan
Write-Host "  docker exec localstack-aws awslocal secretsmanager list-secrets" -ForegroundColor Gray
Write-Host "`n  # Obtener token manualmente:" -ForegroundColor Cyan
Write-Host '  curl -X POST http://localhost:8080/realms/ecommerce/protocol/openid-connect/token -d "grant_type=client_credentials&client_id=reports-service&client_secret=reports-secret-2026"' -ForegroundColor Gray
Write-Host "`n  # Ver logs de Lambda:" -ForegroundColor Cyan
Write-Host '  docker exec localstack-aws awslocal logs filter-log-events --log-group-name "/aws/lambda/ReportsGeneratorFunction" --limit 20' -ForegroundColor Gray
