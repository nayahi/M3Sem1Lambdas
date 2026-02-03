#Requires -Version 7

<#
.SYNOPSIS
    Corrige event source mapping agregando MaximumRetryAttempts
.DESCRIPTION
    Actualiza el mapping existente para configurar reintentos que permitan que mensajes vayan a DLQ
#>

$ErrorActionPreference = "Stop"
$ContainerName = "localstack-aws"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         CORRECCIÓN: AGREGAR MAXIMUM RETRY ATTEMPTS            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`n🔍 Problema identificado:" -ForegroundColor Yellow
Write-Host "   El event source mapping NO tiene configurado MaximumRetryAttempts" -ForegroundColor Gray
Write-Host "   Sin reintentos, los mensajes NO van a DLQ después de fallar" -ForegroundColor Gray

Write-Host "`n[1/4] 🔍 Buscando event source mapping..." -ForegroundColor Cyan

$mappings = docker exec $ContainerName awslocal lambda list-event-source-mappings `
    --function-name EmailBatchProcessorFunction `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ❌ Error: Lambda o mapping no encontrado" -ForegroundColor Red
    exit 1
}

$mappingsData = $mappings | ConvertFrom-Json

if ($mappingsData.EventSourceMappings.Count -eq 0) {
    Write-Host "  ❌ Error: No existe event source mapping" -ForegroundColor Red
    Write-Host "     Ejecuta Deploy-All-Lambdas-v2.ps1 primero" -ForegroundColor Yellow
    exit 1
}

$mapping = $mappingsData.EventSourceMappings[0]
$mappingUuid = $mapping.UUID
$currentRetries = $mapping.MaximumRetryAttempts

Write-Host "  ✅ Mapping encontrado" -ForegroundColor Green
Write-Host "     UUID: $mappingUuid" -ForegroundColor Gray
Write-Host "     MaximumRetryAttempts actual: $currentRetries" -ForegroundColor Gray

if ($currentRetries -ge 2) {
    Write-Host "`n  ✅ Mapping ya tiene MaximumRetryAttempts configurado ($currentRetries)" -ForegroundColor Green
    Write-Host "     No se necesita actualización" -ForegroundColor Gray
    exit 0
}

Write-Host "`n[2/4] 🔧 Obteniendo DLQ ARN..." -ForegroundColor Cyan

$dlqName = "email-notifications-dlq"
$dlqUrl = docker exec $ContainerName awslocal sqs get-queue-url --queue-name $dlqName --query 'QueueUrl' --output text 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ❌ Error: DLQ no existe - ejecuta Deploy-All-Lambdas-v2.ps1" -ForegroundColor Red
    exit 1
}

$dlqArn = docker exec $ContainerName awslocal sqs get-queue-attributes `
    --queue-url $dlqUrl.Trim() `
    --attribute-names QueueArn `
    --query 'Attributes.QueueArn' `
    --output text

$dlqArn = $dlqArn.Trim()

Write-Host "  ✅ DLQ encontrada" -ForegroundColor Green
Write-Host "     ARN: $dlqArn" -ForegroundColor Gray

Write-Host "`n[3/4] 🔧 Actualizando mapping con MaximumRetryAttempts=2..." -ForegroundColor Cyan

# Intentar actualizar
$updateResult = docker exec $ContainerName awslocal lambda update-event-source-mapping `
    --uuid $mappingUuid `
    --maximum-retry-attempts 2 `
    --destination-config "{`"OnFailure`":{`"Destination`":`"$dlqArn`"}}" `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ Mapping actualizado exitosamente" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ Update falló, intentando método alternativo (recrear)..." -ForegroundColor Yellow
    
    # Obtener queue ARN
    $queueUrl = "http://localhost:4566/000000000000/email-notifications-queue"
    $queueArn = docker exec $ContainerName awslocal sqs get-queue-attributes `
        --queue-url $queueUrl `
        --attribute-names QueueArn `
        --query 'Attributes.QueueArn' `
        --output text
    
    $queueArn = $queueArn.Trim()
    
    # Eliminar mapping viejo
    Write-Host "     → Eliminando mapping antiguo..." -ForegroundColor Gray
    docker exec $ContainerName awslocal lambda delete-event-source-mapping --uuid $mappingUuid 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    # Crear nuevo mapping
    Write-Host "     → Creando nuevo mapping con MaximumRetryAttempts..." -ForegroundColor Gray
    docker exec $ContainerName awslocal lambda create-event-source-mapping `
        --function-name EmailBatchProcessorFunction `
        --event-source-arn $queueArn `
        --batch-size 10 `
        --maximum-retry-attempts 2 `
        --enabled `
        --destination-config "{`"OnFailure`":{`"Destination`":`"$dlqArn`"}}" `
        --output json 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ Mapping recreado exitosamente" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Error recreando mapping" -ForegroundColor Red
        exit 1
    }
}

Write-Host "`n[4/4] ✅ Verificando configuración final..." -ForegroundColor Cyan

$finalMappings = docker exec $ContainerName awslocal lambda list-event-source-mappings `
    --function-name EmailBatchProcessorFunction `
    --output json | ConvertFrom-Json

$finalMapping = $finalMappings.EventSourceMappings[0]
$finalRetries = $finalMapping.MaximumRetryAttempts
$finalDestConfig = $finalMapping.DestinationConfig

Write-Host "  ✅ Configuración actualizada:" -ForegroundColor Green
Write-Host "     MaximumRetryAttempts: $finalRetries" -ForegroundColor Gray
Write-Host "     DLQ Configurada: $($null -ne $finalDestConfig.OnFailure)" -ForegroundColor Gray

if ($null -ne $finalDestConfig.OnFailure) {
    Write-Host "     DLQ ARN: $($finalDestConfig.OnFailure.Destination)" -ForegroundColor Gray
}

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    ✅ CORRECCIÓN COMPLETADA                    ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n📋 CONFIGURACIÓN FINAL:" -ForegroundColor Yellow
Write-Host "   • MaximumRetryAttempts: 2 reintentos" -ForegroundColor Gray
Write-Host "   • DLQ configurada: email-notifications-dlq" -ForegroundColor Gray
Write-Host "   • Después de 2 fallos → Mensaje va a DLQ" -ForegroundColor Gray

Write-Host "`n🧪 PRÓXIMOS PASOS:" -ForegroundColor Yellow
Write-Host "   1. Asegúrate que NotificationService esté CAÍDO:" -ForegroundColor Gray
Write-Host "      docker stop notificationservice" -ForegroundColor Cyan
Write-Host "" -ForegroundColor Gray
Write-Host "   2. Ejecuta el test:" -ForegroundColor Gray
Write-Host "      .\Deployment-Guides\Test-Lambdas-Resilience.ps1 -Scenario EmailBatchCircuit" -ForegroundColor Cyan
Write-Host "" -ForegroundColor Gray
Write-Host "   3. Espera 2-3 minutos (tiempo de reintentos)" -ForegroundColor Gray
Write-Host "" -ForegroundColor Gray
Write-Host "   4. Verifica DLQ:" -ForegroundColor Gray
Write-Host "      docker exec localstack-aws awslocal sqs get-queue-attributes \" -ForegroundColor Cyan
Write-Host "          --queue-url http://localhost:4566/000000000000/email-notifications-dlq \" -ForegroundColor Cyan
Write-Host "          --attribute-names ApproximateNumberOfMessages" -ForegroundColor Cyan

Write-Host "`n⏱️ TIEMPO DE REINTENTOS ESPERADO:" -ForegroundColor Yellow
Write-Host "   Intento 1: Lambda procesa → FALLA (throw)" -ForegroundColor Gray
Write-Host "   Espera:    ~30-60 segundos" -ForegroundColor Gray
Write-Host "   Intento 2: Lambda procesa → FALLA (throw)" -ForegroundColor Gray
Write-Host "   Espera:    ~60-120 segundos" -ForegroundColor Gray
Write-Host "   Después:   Mensaje movido a DLQ ✅" -ForegroundColor Gray
Write-Host "   TOTAL:     ~2-3 minutos por mensaje" -ForegroundColor Gray