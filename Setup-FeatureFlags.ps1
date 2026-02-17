#Requires -Version 7

<#
.SYNOPSIS
    Configura Feature Flags en Secrets Manager de LocalStack para Semana 5
.DESCRIPTION
    Crea los feature flags necesarios para la demostración de Strangler Fig Pattern.
    Los flags controlan el enrutamiento de notificaciones: gRPC vs Lambda
.EXAMPLE
    .\Setup-FeatureFlags.ps1
    .\Setup-FeatureFlags.ps1 -EnableLambda -Rollout 50
#>

param(
    [switch]$EnableLambda,
    [int]$Rollout = 0,
    [string]$ContainerName = "localstack-aws"
)

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     SEMANA 5: SETUP FEATURE FLAGS EN LOCALSTACK              ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────
# 1. Verificar LocalStack
# ─────────────────────────────────────────────────────────────────
Write-Host "`n[1/4] 🔍 Verificando LocalStack..." -ForegroundColor Yellow
try {
    $health = Invoke-WebRequest -Uri "http://localhost:4566/_localstack/health" -UseBasicParsing
    Write-Host "  ✅ LocalStack disponible" -ForegroundColor Green
} catch {
    Write-Host "  ❌ LocalStack no está disponible. Ejecuta 'docker-compose up -d' primero." -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────
# 2. Crear/Actualizar Feature Flag: use_lambda_notifications
# ─────────────────────────────────────────────────────────────────
Write-Host "`n[2/4] 🏷️ Configurando feature flag: use_lambda_notifications..." -ForegroundColor Yellow

$flagEnabled = if ($EnableLambda) { "true" } else { "false" }
$flagValue = "{`"Enabled`":$flagEnabled,`"Rollout`":$Rollout,`"Description`":`"Controla migración de NotificationService a Lambda`"}"

# Intentar obtener el secreto primero (para decidir si crear o actualizar)
$secretExists = $false
try {
    docker exec $ContainerName awslocal secretsmanager get-secret-value `
        --secret-id "feature-flags/use_lambda_notifications" 2>&1 | Out-Null
    $secretExists = ($LASTEXITCODE -eq 0)
} catch {
    $secretExists = $false
}

if ($secretExists) {
    Write-Host "  🔄 Flag existente, actualizando..." -ForegroundColor Yellow
    docker exec $ContainerName awslocal secretsmanager put-secret-value `
        --secret-id "feature-flags/use_lambda_notifications" `
        --secret-string $flagValue | Out-Null
    Write-Host "  ✅ Flag actualizado" -ForegroundColor Green
} else {
    Write-Host "  🆕 Creando flag nuevo..." -ForegroundColor Yellow
    docker exec $ContainerName awslocal secretsmanager create-secret `
        --name "feature-flags/use_lambda_notifications" `
        --secret-string $flagValue `
        --description "Semana 5: Controla migración NotificationService → Lambda" | Out-Null
    Write-Host "  ✅ Flag creado" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────
# 3. Verificar el flag creado
# ─────────────────────────────────────────────────────────────────
Write-Host "`n[3/4] 🔍 Verificando flag..." -ForegroundColor Yellow

$result = docker exec $ContainerName awslocal secretsmanager get-secret-value `
    --secret-id "feature-flags/use_lambda_notifications" `
    --query 'SecretString' --output text

Write-Host "  📋 Valor actual: $result" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────
# 4. Mostrar resumen y comandos útiles
# ─────────────────────────────────────────────────────────────────
Write-Host "`n[4/4] 📊 Resumen:" -ForegroundColor Yellow
Write-Host "  🏷️ Flag: feature-flags/use_lambda_notifications" -ForegroundColor White
Write-Host "  📌 Enabled: $flagEnabled" -ForegroundColor White
Write-Host "  📌 Rollout: $Rollout%" -ForegroundColor White

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     ✅ FEATURE FLAGS CONFIGURADOS                             ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n💡 Comandos útiles para la demostración:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  # Habilitar Lambda al 10% (canary inicial):" -ForegroundColor Gray
Write-Host "  .\Setup-FeatureFlags.ps1 -EnableLambda -Rollout 10" -ForegroundColor White
Write-Host ""
Write-Host "  # Subir a 50% (A/B testing):" -ForegroundColor Gray
Write-Host "  .\Setup-FeatureFlags.ps1 -EnableLambda -Rollout 50" -ForegroundColor White
Write-Host ""
Write-Host "  # 100% Lambda (migración completa):" -ForegroundColor Gray
Write-Host "  .\Setup-FeatureFlags.ps1 -EnableLambda -Rollout 100" -ForegroundColor White
Write-Host ""
Write-Host "  # Rollback instantáneo a gRPC:" -ForegroundColor Gray
Write-Host "  .\Setup-FeatureFlags.ps1" -ForegroundColor White
Write-Host ""
Write-Host "  # Verificar flag manualmente:" -ForegroundColor Gray
Write-Host "  docker exec $ContainerName awslocal secretsmanager get-secret-value --secret-id feature-flags/use_lambda_notifications --query SecretString --output text" -ForegroundColor White