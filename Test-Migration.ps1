#Requires -Version 7

<#
.SYNOPSIS
    Prueba el flujo de migración Semana 5: Feature Flag → Facade → Lambda/gRPC
.DESCRIPTION
    Ejecuta pruebas del Strangler Fig Pattern:
    1. Flag OFF → verifica ruta gRPC
    2. Flag ON al 50% → verifica canary
    3. Flag ON al 100% → verifica migración completa
    4. Simula fallo Lambda → verifica fallback a gRPC
.EXAMPLE
    .\Test-Migration.ps1
#>

param(
    [string]$ContainerName = "localstack-aws"
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────
# FUNCIÓN: Crear una orden con saga vía BFFAPIGW (REST → gRPC)
# ─────────────────────────────────────────────────────────────────
function New-OrderWithSaga {
    param(
        [int]$OrderNumber = 1,
        [string]$BffUrl = "http://localhost:5000"
    )

    $orderPayload = @{
        userId = 1
        shippingAddress = "Test Address $OrderNumber, San José, Costa Rica"
        items = @(
            @{
                productId = 1
                quantity  = 1
                unitPrice = 29.99
            }
        )
    } | ConvertTo-Json -Depth 3

    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $response = Invoke-RestMethod -Uri "$BffUrl/api/orders/saga" `
            -Method Post `
            -Body $orderPayload `
            -ContentType "application/json" `
            -TimeoutSec 30

        $stopwatch.Stop()

        Write-Host "  ✅ Orden #$OrderNumber creada: ID=$($response.id), Status=$($response.status), Tiempo=$($stopwatch.ElapsedMilliseconds)ms" -ForegroundColor Green
        return $response
    }
    catch {
        Write-Host "  ❌ Orden #$OrderNumber falló: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────
# FUNCIÓN: Crear N órdenes y mostrar resumen de rutas
# ─────────────────────────────────────────────────────────────────
function New-MultipleOrders {
    param(
        [int]$Count = 10,
        [string]$BffUrl = "http://localhost:5000"
    )

    Write-Host "`n  🛒 Creando $Count órdenes con saga..." -ForegroundColor Yellow

    $results = @()
    for ($i = 1; $i -le $Count; $i++) {
        $result = New-OrderWithSaga -OrderNumber $i -BffUrl $BffUrl
        $results += $result
        # Pequeña pausa para que los logs sean legibles
        Start-Sleep -Milliseconds 500
    }

    # Resumen
    $successful = ($results | Where-Object { $_ -ne $null }).Count
    $failed = $Count - $successful

    Write-Host "`n  📊 Resumen: $successful exitosas, $failed fallidas de $Count total" -ForegroundColor Cyan
    Write-Host "  💡 Revisa los logs del OrderService para ver las rutas (gRPC vs Lambda vs fallback)" -ForegroundColor Yellow
}

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     SEMANA 5: TEST DE MIGRACIÓN - STRANGLER FIG              ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────
# VERIFICACIONES PREVIAS
# ─────────────────────────────────────────────────────────────────
Write-Host "`n🔍 Verificaciones previas..." -ForegroundColor Yellow

# Verificar LocalStack
try {
    Invoke-WebRequest -Uri "http://localhost:4566/_localstack/health" -UseBasicParsing | Out-Null
    Write-Host "  ✅ LocalStack disponible" -ForegroundColor Green
} catch {
    Write-Host "  ❌ LocalStack no disponible" -ForegroundColor Red
    exit 1
}

# Verificar que EmailBatch Lambda está desplegada
$lambdaCheck = docker exec $ContainerName awslocal lambda get-function `
    --function-name EmailBatchProcessorFunction 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ⚠️ EmailBatch Lambda no encontrada. Ejecuta Deploy-All-Lambdas.ps1 primero" -ForegroundColor Yellow
    Write-Host "  ⚠️ Continuando — las pruebas de Lambda mostrarán el fallback a gRPC" -ForegroundColor Yellow
} else {
    Write-Host "  ✅ EmailBatch Lambda disponible" -ForegroundColor Green
}

# Verificar cola SQS
$queueCheck = docker exec $ContainerName awslocal sqs get-queue-url `
    --queue-name email-notifications-queue 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ Cola SQS email-notifications-queue disponible" -ForegroundColor Green
} else {
    Write-Host "  ❌ Cola SQS no encontrada" -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────
# TEST 1: FLAG OFF → Todo va por gRPC
# ─────────────────────────────────────────────────────────────────
Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "📋 TEST 1: Flag OFF — Ruta gRPC (comportamiento original)" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

# Configurar flag OFF
$flagOff = '{"Enabled":false,"Rollout":0,"Description":"Test: OFF"}'

# Verificar si existe y crear/actualizar
$exists = docker exec $ContainerName awslocal secretsmanager describe-secret `
    --secret-id "feature-flags/use_lambda_notifications" 2>&1
if ($LASTEXITCODE -eq 0) {
    docker exec $ContainerName awslocal secretsmanager put-secret-value `
        --secret-id "feature-flags/use_lambda_notifications" `
        --secret-string $flagOff | Out-Null
} else {
    docker exec $ContainerName awslocal secretsmanager create-secret `
        --name "feature-flags/use_lambda_notifications" `
        --secret-string $flagOff | Out-Null
}

Write-Host "  ✅ Flag configurado: OFF" -ForegroundColor Green

# Verificar lectura del flag
$value = docker exec $ContainerName awslocal secretsmanager get-secret-value `
    --secret-id "feature-flags/use_lambda_notifications" `
    --query 'SecretString' --output text
Write-Host "  📋 Valor: $value" -ForegroundColor Gray

# ── En TEST 1 (Flag OFF): ──────────────────────────────
Write-Host "`n  💡 Acción del docente: Ejecutar una orden con saga (CreateOrderWithSaga)" -ForegroundColor Yellow
Write-Host "  💡 Resultado esperado: Logs muestran 'Facade→gRPC' o ruta original" -ForegroundColor Yellow
Write-Host "`n  🛒 Ejecutando 1 orden de prueba (esperado: ruta gRPC)..." -ForegroundColor Yellow
New-OrderWithSaga -OrderNumber 1


# ─────────────────────────────────────────────────────────────────
# TEST 2: FLAG ON, ROLLOUT 50% → Canary
# ─────────────────────────────────────────────────────────────────
Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "📋 TEST 2: Flag ON, Rollout 50% — Canary Deployment" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

$flagCanary = '{"Enabled":true,"Rollout":50,"Description":"Test: Canary 50%"}'
docker exec $ContainerName awslocal secretsmanager put-secret-value `
    --secret-id "feature-flags/use_lambda_notifications" `
    --secret-string $flagCanary | Out-Null

Write-Host "  ✅ Flag configurado: ON, Rollout=50%" -ForegroundColor Green

$value = docker exec $ContainerName awslocal secretsmanager get-secret-value `
    --secret-id "feature-flags/use_lambda_notifications" `
    --query 'SecretString' --output text
Write-Host "  📋 Valor: $value" -ForegroundColor Gray

Write-Host "`n  💡 Acción del docente: Ejecutar ~10 órdenes" -ForegroundColor Yellow
Write-Host "  💡 Resultado esperado: ~50% logs 'Facade→SQS', ~50% 'Facade→gRPC'" -ForegroundColor Yellow
# ── En TEST 2 (Canary 50%): ────────────────────────────
Write-Host "`n  🛒 Ejecutando 10 órdenes (esperado: ~50% Lambda, ~50% gRPC)..." -ForegroundColor Yellow
New-MultipleOrders -Count 10


# Verificar mensajes en cola SQS (si alguno fue enrutado a Lambda)
Start-Sleep -Seconds 2
$queueAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes `
    --queue-url "http://localhost:4566/000000000000/email-notifications-queue" `
    --attribute-names ApproximateNumberOfMessages `
    --query 'Attributes.ApproximateNumberOfMessages' --output text 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  📊 Mensajes en cola SQS: $queueAttrs" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────
# TEST 3: FLAG ON, ROLLOUT 100% → Migración completa
# ─────────────────────────────────────────────────────────────────
Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "📋 TEST 3: Flag ON, Rollout 100% — Migración completa" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

$flagFull = '{"Enabled":true,"Rollout":100,"Description":"Test: Full migration"}'
docker exec $ContainerName awslocal secretsmanager put-secret-value `
    --secret-id "feature-flags/use_lambda_notifications" `
    --secret-string $flagFull | Out-Null

Write-Host "  ✅ Flag configurado: ON, Rollout=100%" -ForegroundColor Green
Write-Host "`n  💡 Acción: Ejecutar órdenes — TODAS deberían ir por Lambda" -ForegroundColor Yellow
# ── En TEST 3 (100% Lambda): ───────────────────────────
Write-Host "`n  🛒 Ejecutando 5 órdenes (esperado: TODAS por Lambda)..." -ForegroundColor Yellow
New-MultipleOrders -Count 5

# ─────────────────────────────────────────────────────────────────
# TEST 4: ROLLBACK INSTANTÁNEO
# ─────────────────────────────────────────────────────────────────
Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "📋 TEST 4: Rollback instantáneo → Todo vuelve a gRPC" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

docker exec $ContainerName awslocal secretsmanager put-secret-value `
    --secret-id "feature-flags/use_lambda_notifications" `
    --secret-string $flagOff | Out-Null

Write-Host "  ✅ Flag configurado: OFF — Rollback completo" -ForegroundColor Green
Write-Host "  ⏱️ Tiempo de rollback: < 1 segundo (+ 30s cache TTL)" -ForegroundColor Cyan
Write-Host "`n  💡 Acción: Ejecutar órdenes — TODAS deberían ir por gRPC" -ForegroundColor Yellow
# ── En TEST 4 (Rollback): ──────────────────────────────
Write-Host "`n  🛒 Ejecutando 3 órdenes post-rollback (esperado: TODAS por gRPC)..." -ForegroundColor Yellow
New-MultipleOrders -Count 3


# ─────────────────────────────────────────────────────────────────
# RESUMEN
# ─────────────────────────────────────────────────────────────────
Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     ✅ TESTS DE MIGRACIÓN CONFIGURADOS                        ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n📊 Resumen de escenarios:" -ForegroundColor Yellow
Write-Host "  Test 1: Flag OFF       → gRPC (original)        ✅ Configurado" -ForegroundColor White
Write-Host "  Test 2: Rollout 50%    → Canary deployment       ✅ Configurado" -ForegroundColor White
Write-Host "  Test 3: Rollout 100%   → Migración completa      ✅ Configurado" -ForegroundColor White
Write-Host "  Test 4: Rollback       → gRPC (instantáneo)      ✅ Configurado" -ForegroundColor White

Write-Host "`n💡 Para ver el flujo completo:" -ForegroundColor Yellow
Write-Host "  1. Abrir logs del OrderService (terminal)" -ForegroundColor Gray
Write-Host "  2. Ejecutar este script" -ForegroundColor Gray
Write-Host "  3. Después de cada cambio de flag, crear una orden con saga" -ForegroundColor Gray
Write-Host "  4. Observar en los logs qué ruta toma cada notificación" -ForegroundColor Gray
Write-Host "  5. Verificar mensajes SQS con:" -ForegroundColor Gray
Write-Host "     docker exec $ContainerName awslocal sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/email-notifications-queue --attribute-names All" -ForegroundColor White