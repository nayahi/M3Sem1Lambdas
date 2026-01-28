#Requires -Version 7

<#
.SYNOPSIS
    Configura Dead Letter Queue para EmailBatch Lambda
.DESCRIPTION
    Crea la cola email-notifications-dlq y configura el event source mapping
.EXAMPLE
    .\Setup-EmailBatch-DLQ.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           CONFIGURAR DLQ PARA EMAILBATCH LAMBDA                ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$ContainerName = "localstack-aws"
$LocalStackEndpoint = "http://localhost:4566"

# Verificar LocalStack
Write-Host "`n🔍 Verificando LocalStack..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "$LocalStackEndpoint/_localstack/health" -UseBasicParsing
    Write-Host "✅ LocalStack está disponible" -ForegroundColor Green
} catch {
    Write-Host "❌ LocalStack no está disponible" -ForegroundColor Red
    exit 1
}

# PASO 1: Crear DLQ
Write-Host "`n[1/4] 🗑️ Creando Dead Letter Queue..." -ForegroundColor Cyan

$dlqName = "email-notifications-dlq"
$checkDlq = docker exec $ContainerName awslocal sqs get-queue-url --queue-name $dlqName 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  📦 Creando cola: $dlqName" -ForegroundColor Yellow
    
    $createDlq = docker exec $ContainerName awslocal sqs create-queue --queue-name $dlqName 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ DLQ creada exitosamente" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Error creando DLQ: $createDlq" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  ✅ DLQ ya existe" -ForegroundColor Green
}

# Obtener ARN de la DLQ
$dlqUrl = docker exec $ContainerName awslocal sqs get-queue-url --queue-name $dlqName --query 'QueueUrl' --output text
$dlqAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes --queue-url $dlqUrl --attribute-names QueueArn --output json | ConvertFrom-Json
$dlqArn = $dlqAttrs.Attributes.QueueArn

Write-Host "  📋 DLQ ARN: $dlqArn" -ForegroundColor Gray

# PASO 2: Obtener event source mapping UUID
Write-Host "`n[2/4] 🔍 Buscando event source mapping de EmailBatch..." -ForegroundColor Cyan

$mappings = docker exec $ContainerName awslocal lambda list-event-source-mappings `
    --function-name EmailBatchProcessorFunction `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ❌ Error listando event source mappings" -ForegroundColor Red
    exit 1
}

$mappingsObj = $mappings | ConvertFrom-Json

if ($mappingsObj.EventSourceMappings.Count -eq 0) {
    Write-Host "  ❌ No se encontró event source mapping para EmailBatchProcessorFunction" -ForegroundColor Red
    Write-Host "     Ejecuta Deploy-All-Lambdas-v2.ps1 primero" -ForegroundColor Yellow
    exit 1
}

$mappingUuid = $mappingsObj.EventSourceMappings[0].UUID
$currentState = $mappingsObj.EventSourceMappings[0].State

Write-Host "  ✅ Event Source Mapping encontrado" -ForegroundColor Green
Write-Host "     UUID: $mappingUuid" -ForegroundColor Gray
Write-Host "     Estado actual: $currentState" -ForegroundColor Gray

# PASO 3: Actualizar event source mapping con DLQ
Write-Host "`n[3/4] 🔧 Configurando DLQ en event source mapping..." -ForegroundColor Cyan

# Configuración de DLQ para event source mapping
$onFailureConfig = @{
    Destination = $dlqArn
} | ConvertTo-Json -Compress

Write-Host "  📝 Configuración DLQ: $onFailureConfig" -ForegroundColor Gray

# Actualizar event source mapping
$updateResult = docker exec $ContainerName awslocal lambda update-event-source-mapping `
    --uuid $mappingUuid `
    --destination-config "{`"OnFailure`":{`"Destination`":`"$dlqArn`"}}" `
    --batch-size 10 `
    --maximum-batching-window-in-seconds 0 `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ Event source mapping actualizado con DLQ" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ Advertencia al actualizar: $updateResult" -ForegroundColor Yellow
    Write-Host "  Intentando método alternativo..." -ForegroundColor Yellow
    
    # Método alternativo: Eliminar y recrear
    docker exec $ContainerName awslocal lambda delete-event-source-mapping --uuid $mappingUuid 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    $queueUrl = "http://localhost:4566/000000000000/email-notifications-queue"
    $queueAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes --queue-url $queueUrl --attribute-names QueueArn --output json | ConvertFrom-Json
    $queueArn = $queueAttrs.Attributes.QueueArn
    
    docker exec $ContainerName awslocal lambda create-event-source-mapping `
        --function-name EmailBatchProcessorFunction `
        --event-source-arn $queueArn `
        --batch-size 10 `
        --enabled `
        --destination-config "{`"OnFailure`":{`"Destination`":`"$dlqArn`"}}" `
        --output json 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ Event source mapping recreado con DLQ" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Error configurando DLQ" -ForegroundColor Red
    }
}

# PASO 4: Verificar configuración
Write-Host "`n[4/4] ✅ Verificando configuración final..." -ForegroundColor Cyan

$finalMappings = docker exec $ContainerName awslocal lambda list-event-source-mappings `
    --function-name EmailBatchProcessorFunction `
    --output json | ConvertFrom-Json

$destinationConfig = $finalMappings.EventSourceMappings[0].DestinationConfig

Write-Host "  📋 Configuración actual:" -ForegroundColor Yellow
Write-Host "     Function: EmailBatchProcessorFunction" -ForegroundColor Gray
Write-Host "     Source Queue: email-notifications-queue" -ForegroundColor Gray
Write-Host "     DLQ: $dlqName" -ForegroundColor Gray
Write-Host "     Batch Size: 10" -ForegroundColor Gray

# Listar todas las colas SQS
Write-Host "`n📋 Colas SQS disponibles:" -ForegroundColor Cyan
docker exec $ContainerName awslocal sqs list-queues --output json | ConvertFrom-Json | ForEach-Object {
    $_.QueueUrls | ForEach-Object {
        $queueName = $_.Split('/')[-1]
        Write-Host "  • $queueName" -ForegroundColor Gray
    }
}

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    ✅ CONFIGURACIÓN COMPLETADA                 ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n💡 Próximos pasos:" -ForegroundColor Cyan
Write-Host "  1. Verificar DLQ vacía:" -ForegroundColor White
Write-Host "     docker exec localstack-aws awslocal sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/email-notifications-dlq --attribute-names ApproximateNumberOfMessages" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Ejecutar test de resiliencia:" -ForegroundColor White
Write-Host "     .\Test-Lambdas-Resilience.ps1 -Scenario EmailBatchCircuit" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Verificar mensajes en DLQ después del test:" -ForegroundColor White
Write-Host "     docker exec localstack-aws awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/email-notifications-dlq --max-number-of-messages 10" -ForegroundColor Gray
