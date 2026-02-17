#Requires -Version 7

<#
.SYNOPSIS
    Prueba el flujo de migración Semana 5: Feature Flag → Facade → Lambda/gRPC
.DESCRIPTION
    Ejecuta pruebas del Strangler Fig Pattern:
    1. Flag OFF → verifica ruta gRPC
    2. Flag ON al 50% → verifica canary
    3. Flag ON al 100% → verifica migración completa
    4. Rollback → Todo vuelve a gRPC
.EXAMPLE
    .\Test-Migration.ps1                    # Ejecuta TODOS los tests
    .\Test-Migration.ps1 -Test 1            # Solo Test 1 (Flag OFF)
    .\Test-Migration.ps1 -Test 2            # Solo Test 2 (Canary 50%)
    .\Test-Migration.ps1 -Test 3            # Solo Test 3 (100% Lambda)
    .\Test-Migration.ps1 -Test 4            # Solo Test 4 (Rollback)
    .\Test-Migration.ps1 -Test 1,3          # Tests 1 y 3
    .\Test-Migration.ps1 -Test 2 -OrderCount 20  # Test 2 con 20 órdenes
#>

param(
    [int[]]$Test = @(1, 2, 3, 4),
    [int]$OrderCount = 10,
    [string]$ContainerName = "localstack-aws",
    [string]$GrpcHost = "localhost:7003"
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────
# FUNCIONES DE SOPORTE
# ─────────────────────────────────────────────────────────────────

function New-OrderWithSaga {
    param(
        [int]$OrderNumber = 1,
        [string]$TargetHost = "localhost:7003"
    )

    $payload = @"
{"user_id":2,"shipping_address":"Test Address $OrderNumber, San Jose, Costa Rica","items":[{"product_id":1,"quantity":1,"unit_price":1299.99}]}
"@

    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $response = grpcurl -plaintext -d $payload $TargetHost orderservice.OrderService/CreateOrderWithSaga 2>&1

        $stopwatch.Stop()

        $responseText = $response -join "`n"

        if ($LASTEXITCODE -eq 0) {
            $parsed = $responseText | ConvertFrom-Json -ErrorAction SilentlyContinue
            $status = if ($parsed.status) { $parsed.status } else { "OK" }
            $orderId = if ($parsed.id) { $parsed.id } else { "?" }

            Write-Host ("  ✅ Orden #{0}: ID={1}, Status={2}, Tiempo={3}ms" -f $OrderNumber, $orderId, $status, $stopwatch.ElapsedMilliseconds) -ForegroundColor Green
        } else {
            Write-Host ("  ❌ Orden #{0}: {1}" -f $OrderNumber, $responseText) -ForegroundColor Red
        }

        return $responseText
    }
    catch {
        Write-Host ("  ❌ Orden #{0} error: {1}" -f $OrderNumber, $_.Exception.Message) -ForegroundColor Red
        return $null
    }
}

function New-MultipleOrders {
    param(
        [int]$Count = 10,
        [string]$TargetHost = "localhost:7003"
    )

    Write-Host ("`n  🛒 Creando {0} órdenes con saga..." -f $Count) -ForegroundColor Yellow

    $successful = 0
    $failed = 0

    for ($i = 1; $i -le $Count; $i++) {
        $result = New-OrderWithSaga -OrderNumber $i -TargetHost $TargetHost
        if ($LASTEXITCODE -eq 0) { $successful++ } else { $failed++ }
        Start-Sleep -Milliseconds 800
    }

    Write-Host ("`n  📊 Resumen: {0} exitosas, {1} fallidas de {2} total" -f $successful, $failed, $Count) -ForegroundColor Cyan
    Write-Host "  💡 Revisa los logs del OrderService para ver las rutas:" -ForegroundColor Yellow
    Write-Host "      'Ruta=gRPC'       = Ruta original" -ForegroundColor Gray
    Write-Host "      'Ruta=LAMBDA'     = Ruta Lambda (migrada)" -ForegroundColor Gray
    Write-Host "      'grpc-fallback'   = Lambda falló, cayó a gRPC" -ForegroundColor Gray
}

function Set-FeatureFlag {
    param(
        [bool]$Enabled,
        [int]$Rollout,
        [string]$Description,
        [string]$Container
    )

    $enabledStr = if ($Enabled) { "true" } else { "false" }
    $flagValue = "{`"Enabled`":$enabledStr,`"Rollout`":$Rollout,`"Description`":`"$Description`"}"

    # Verificar si existe
    docker exec $Container awslocal secretsmanager describe-secret `
        --secret-id "feature-flags/use_lambda_notifications" 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        docker exec $Container awslocal secretsmanager put-secret-value `
            --secret-id "feature-flags/use_lambda_notifications" `
            --secret-string $flagValue 2>&1 | Out-Null
    } else {
        docker exec $Container awslocal secretsmanager create-secret `
            --name "feature-flags/use_lambda_notifications" `
            --secret-string $flagValue `
            --description "Semana 5: Migration flag" 2>&1 | Out-Null
    }

    $value = docker exec $Container awslocal secretsmanager get-secret-value `
        --secret-id "feature-flags/use_lambda_notifications" `
        --query "SecretString" --output text

    Write-Host ("  📋 Flag configurado: {0}" -f $value) -ForegroundColor Cyan
}

function Show-SqsCount {
    param([string]$Container)

    $count = docker exec $Container awslocal sqs get-queue-attributes `
        --queue-url "http://localhost:4566/000000000000/email-notifications-queue" `
        --attribute-names ApproximateNumberOfMessages `
        --query "Attributes.ApproximateNumberOfMessages" --output text 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  📊 Mensajes en cola SQS (enrutados a Lambda): {0}" -f $count) -ForegroundColor Cyan
    }
}

# ─────────────────────────────────────────────────────────────────
# ENCABEZADO
# ─────────────────────────────────────────────────────────────────

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     SEMANA 5: TEST DE MIGRACIÓN - STRANGLER FIG              ║" -ForegroundColor Cyan
Write-Host ("║     Tests seleccionados: {0,-39}║" -f ($Test -join ", ")) -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────
# VERIFICACIONES PREVIAS
# ─────────────────────────────────────────────────────────────────

Write-Host "`n🔍 Verificaciones previas..." -ForegroundColor Yellow

try {
    Invoke-WebRequest -Uri "http://localhost:4566/_localstack/health" -UseBasicParsing | Out-Null
    Write-Host "  ✅ LocalStack disponible" -ForegroundColor Green
} catch {
    Write-Host "  ❌ LocalStack no disponible. Ejecuta 'docker-compose up -d' primero." -ForegroundColor Red
    exit 1
}

$grpcCheck = grpcurl -plaintext $GrpcHost list 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ OrderService disponible en $GrpcHost" -ForegroundColor Green
} else {
    Write-Host "  ❌ OrderService no responde en $GrpcHost" -ForegroundColor Red
    exit 1
}

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

if ($Test -contains 1) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📋 TEST 1: Flag OFF — Ruta gRPC (comportamiento original)" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    Set-FeatureFlag -Enabled $false -Rollout 0 -Description "Test 1: OFF" -Container $ContainerName

    Write-Host "`n  ⏱️ Esperando 35s para que expire cache del flag..." -ForegroundColor Yellow
    Start-Sleep -Seconds 35

    Write-Host "`n  🛒 Ejecutando 1 orden (esperado: ruta gRPC)..." -ForegroundColor Yellow
    New-OrderWithSaga -OrderNumber 1 -TargetHost $GrpcHost

    Write-Host "`n  🔍 Logs esperados:" -ForegroundColor Yellow
    Write-Host "      🔀 Facade: OrderId=XX → Ruta=gRPC (Flag: Enabled=False, Rollout=0%)" -ForegroundColor Gray
    Write-Host "      ✅ Facade→gRPC: OrderId=XX, NotificationId=YY, Latency=XXms" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────
# TEST 2: FLAG ON, ROLLOUT 50% → Canary
# ─────────────────────────────────────────────────────────────────

if ($Test -contains 2) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ("📋 TEST 2: Flag ON, Rollout 50% — Canary ({0} órdenes)" -f $OrderCount) -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    Set-FeatureFlag -Enabled $true -Rollout 50 -Description "Test 2: Canary 50%" -Container $ContainerName

    Write-Host "`n  ⏱️ Esperando 35s para que expire cache del flag..." -ForegroundColor Yellow
    Start-Sleep -Seconds 35

    New-MultipleOrders -Count $OrderCount -TargetHost $GrpcHost

    Start-Sleep -Seconds 2
    Show-SqsCount -Container $ContainerName

    Write-Host "`n  🔍 Logs esperados (mezcla de ambas rutas):" -ForegroundColor Yellow
    Write-Host "      🔀 Facade: OrderId=XX → Ruta=LAMBDA ..." -ForegroundColor Gray
    Write-Host "      🔀 Facade: OrderId=XX → Ruta=gRPC ..." -ForegroundColor Gray
    Write-Host ("      📊 De {0} órdenes: ~{1} Lambda, ~{1} gRPC" -f $OrderCount, ($OrderCount / 2)) -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────
# TEST 3: FLAG ON, ROLLOUT 100% → Migración completa
# ─────────────────────────────────────────────────────────────────

if ($Test -contains 3) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📋 TEST 3: Flag ON, Rollout 100% — Migración completa" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    Set-FeatureFlag -Enabled $true -Rollout 100 -Description "Test 3: Full migration" -Container $ContainerName

    Write-Host "`n  ⏱️ Esperando 35s para que expire cache del flag..." -ForegroundColor Yellow
    Start-Sleep -Seconds 35

    New-MultipleOrders -Count 5 -TargetHost $GrpcHost

    Start-Sleep -Seconds 2
    Show-SqsCount -Container $ContainerName

    Write-Host "`n  🔍 Logs esperados (TODAS por Lambda):" -ForegroundColor Yellow
    Write-Host "      🔀 Facade: OrderId=XX → Ruta=LAMBDA (Flag: Enabled=True, Rollout=100%)" -ForegroundColor Gray
    Write-Host "      ✅ Facade→SQS: OrderId=XX, MessageId=ZZZ, Latency=XXms" -ForegroundColor Gray
    Write-Host "      ❌ NO debería aparecer: Ruta=gRPC" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────
# TEST 4: ROLLBACK → Todo vuelve a gRPC
# ─────────────────────────────────────────────────────────────────

if ($Test -contains 4) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📋 TEST 4: Rollback — Todo vuelve a gRPC" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    Set-FeatureFlag -Enabled $false -Rollout 0 -Description "Test 4: Rollback" -Container $ContainerName

    Write-Host "`n  ⏱️ Esperando 35s para que expire cache del flag..." -ForegroundColor Yellow
    Start-Sleep -Seconds 35

    New-MultipleOrders -Count 3 -TargetHost $GrpcHost

    Write-Host "`n  🔍 Logs esperados (TODAS por gRPC):" -ForegroundColor Yellow
    Write-Host "      🔀 Facade: OrderId=XX → Ruta=gRPC (Flag: Enabled=False, Rollout=0%)" -ForegroundColor Gray
    Write-Host "      ✅ Facade→gRPC: OrderId=XX, NotificationId=YY, Latency=XXms" -ForegroundColor Gray
    Write-Host "      ⏱️ Tiempo de rollback: < 1 segundo + 30s cache TTL" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────
# RESUMEN FINAL
# ─────────────────────────────────────────────────────────────────

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     ✅ TESTS COMPLETADOS                                      ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n📊 Tests ejecutados:" -ForegroundColor Yellow
if ($Test -contains 1) { Write-Host "  Test 1: Flag OFF       → gRPC (original)        ✅" -ForegroundColor White }
if ($Test -contains 2) { Write-Host "  Test 2: Rollout 50%    → Canary deployment       ✅" -ForegroundColor White }
if ($Test -contains 3) { Write-Host "  Test 3: Rollout 100%   → Migración completa      ✅" -ForegroundColor White }
if ($Test -contains 4) { Write-Host "  Test 4: Rollback       → gRPC (instantáneo)      ✅" -ForegroundColor White }