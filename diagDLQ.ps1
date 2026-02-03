#Requires -Version 7

<#
.SYNOPSIS
    Diagnóstico completo de DLQ para EmailBatch
.DESCRIPTION
    Verifica todas las configuraciones para identificar por qué mensajes no llegan a DLQ
#>

$ErrorActionPreference = "Stop"
$ContainerName = "localstack-aws"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║              DIAGNÓSTICO DLQ - EMAILBATCH                      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# 1. Verificar cola principal
Write-Host "`n[1/8] 📋 Verificando cola PRINCIPAL (email-notifications-queue)..." -ForegroundColor Yellow

$mainQueueUrl = "http://localhost:4566/000000000000/email-notifications-queue"
$mainQueueAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes `
    --queue-url $mainQueueUrl `
    --attribute-names All `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    $queueData = $mainQueueAttrs | ConvertFrom-Json
    $msgCount = $queueData.Attributes.ApproximateNumberOfMessages
    $msgInFlight = $queueData.Attributes.ApproximateNumberOfMessagesNotVisible
    $redrivePolicy = $queueData.Attributes.RedrivePolicy
    
    Write-Host "  ✅ Cola principal existe" -ForegroundColor Green
    Write-Host "     Mensajes visibles: $msgCount" -ForegroundColor Gray
    Write-Host "     Mensajes en procesamiento: $msgInFlight" -ForegroundColor Gray
    Write-Host "     RedrivePolicy: $redrivePolicy" -ForegroundColor Gray
    
    if ($msgCount -eq 0 -and $msgInFlight -eq 0) {
        Write-Host "  ⚠️ PROBLEMA: No hay mensajes en la cola principal" -ForegroundColor Red
        Write-Host "     Sin mensajes, Lambda no se invoca y DLQ permanece vacía" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ❌ Error: Cola principal no existe" -ForegroundColor Red
}

# 2. Verificar DLQ
Write-Host "`n[2/8] 📋 Verificando DLQ (email-notifications-dlq)..." -ForegroundColor Yellow

$dlqUrl = "http://localhost:4566/000000000000/email-notifications-dlq"
$dlqAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes `
    --queue-url $dlqUrl `
    --attribute-names All `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    $dlqData = $dlqAttrs | ConvertFrom-Json
    $dlqMsgCount = $dlqData.Attributes.ApproximateNumberOfMessages
    
    Write-Host "  ✅ DLQ existe" -ForegroundColor Green
    Write-Host "     Mensajes en DLQ: $dlqMsgCount" -ForegroundColor Gray
} else {
    Write-Host "  ❌ Error: DLQ no existe - ejecuta Deploy-All-Lambdas-v2.ps1" -ForegroundColor Red
    exit 1
}

# 3. Verificar event source mapping
Write-Host "`n[3/8] 🔗 Verificando Event Source Mapping..." -ForegroundColor Yellow

$mappings = docker exec $ContainerName awslocal lambda list-event-source-mappings `
    --function-name EmailBatchProcessorFunction `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    $mappingsData = $mappings | ConvertFrom-Json
    
    if ($mappingsData.EventSourceMappings.Count -gt 0) {
        $mapping = $mappingsData.EventSourceMappings[0]
        $uuid = $mapping.UUID
        $state = $mapping.State
        $batchSize = $mapping.BatchSize
        $destConfig = $mapping.DestinationConfig
        
        Write-Host "  ✅ Event Source Mapping existe" -ForegroundColor Green
        Write-Host "     UUID: $uuid" -ForegroundColor Gray
        Write-Host "     Estado: $state" -ForegroundColor Gray
        Write-Host "     BatchSize: $batchSize" -ForegroundColor Gray
        
        if ($state -ne "Enabled") {
            Write-Host "  ❌ PROBLEMA: Mapping está DESHABILITADO" -ForegroundColor Red
            Write-Host "     Lambda no se invocará automáticamente" -ForegroundColor Yellow
        }
        
        if ($null -eq $destConfig -or $null -eq $destConfig.OnFailure) {
            Write-Host "  ⚠️ PROBLEMA: Mapping NO tiene DLQ configurada" -ForegroundColor Red
            Write-Host "     DestinationConfig.OnFailure: NULL" -ForegroundColor Yellow
            Write-Host "     Mensajes fallidos NO irán a DLQ" -ForegroundColor Yellow
        } else {
            $dlqArn = $destConfig.OnFailure.Destination
            Write-Host "     DestinationConfig DLQ: $dlqArn" -ForegroundColor Green
        }
    } else {
        Write-Host "  ❌ PROBLEMA: No existe Event Source Mapping" -ForegroundColor Red
    }
} else {
    Write-Host "  ❌ Error verificando mappings" -ForegroundColor Red
}

# 4. Verificar Lambda existe
Write-Host "`n[4/8] 🔍 Verificando Lambda Function..." -ForegroundColor Yellow

$lambdaInfo = docker exec $ContainerName awslocal lambda get-function `
    --function-name EmailBatchProcessorFunction `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    $lambdaData = $lambdaInfo | ConvertFrom-Json
    $timeout = $lambdaData.Configuration.Timeout
    $memory = $lambdaData.Configuration.MemorySize
    
    Write-Host "  ✅ Lambda existe" -ForegroundColor Green
    Write-Host "     Timeout: ${timeout}s" -ForegroundColor Gray
    Write-Host "     Memory: ${memory}MB" -ForegroundColor Gray
} else {
    Write-Host "  ❌ Lambda no existe" -ForegroundColor Red
}

# 5. Verificar invocaciones recientes de Lambda
Write-Host "`n[5/8] 📊 Verificando invocaciones recientes de Lambda..." -ForegroundColor Yellow

$logStreams = docker exec $ContainerName awslocal logs describe-log-streams `
    --log-group-name "/aws/lambda/EmailBatchProcessorFunction" `
    --order-by LastEventTime `
    --descending `
    --max-items 5 `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    $streamsData = $logStreams | ConvertFrom-Json
    
    if ($streamsData.logStreams.Count -gt 0) {
        Write-Host "  ✅ Lambda ha sido invocada recientemente" -ForegroundColor Green
        Write-Host "     Log streams encontrados: $($streamsData.logStreams.Count)" -ForegroundColor Gray
        
        foreach ($stream in $streamsData.logStreams) {
            $streamName = $stream.logStreamName
            $lastEvent = $stream.lastEventTimestamp
            Write-Host "     - $streamName (último evento: $lastEvent)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  ⚠️ PROBLEMA: Lambda NUNCA ha sido invocada" -ForegroundColor Red
        Write-Host "     Sin invocaciones, no puede fallar, DLQ permanece vacía" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ⚠️ No hay logs (Lambda nunca invocada)" -ForegroundColor Yellow
}

# 6. Revisar logs más recientes
Write-Host "`n[6/8] 📝 Revisando logs más recientes (últimos 20)..." -ForegroundColor Yellow

$recentLogs = docker exec $ContainerName awslocal logs tail /aws/lambda/EmailBatchProcessorFunction --since 10m 2>&1 | Select-Object -Last 20

if ($recentLogs) {
    Write-Host "  Últimas líneas de logs:" -ForegroundColor Gray
    $recentLogs | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Write-Host "  ⚠️ Sin logs recientes" -ForegroundColor Yellow
}

# 7. Verificar configuración de reintentos en SQS
Write-Host "`n[7/8] 🔄 Verificando configuración de reintentos..." -ForegroundColor Yellow

$queueAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes `
    --queue-url $mainQueueUrl `
    --attribute-names ReceiveMessageWaitTimeSeconds,VisibilityTimeout,MessageRetentionPeriod `
    --output json | ConvertFrom-Json

$visibilityTimeout = $queueAttrs.Attributes.VisibilityTimeout
$retention = $queueAttrs.Attributes.MessageRetentionPeriod

Write-Host "  VisibilityTimeout: ${visibilityTimeout}s" -ForegroundColor Gray
Write-Host "  MessageRetentionPeriod: ${retention}s ($([int]$retention / 3600) horas)" -ForegroundColor Gray

# 8. Probar envío manual de mensaje
Write-Host "`n[8/8] 🧪 ¿Quieres enviar un mensaje de prueba? (S/N)" -ForegroundColor Yellow
$response = Read-Host "Respuesta"

if ($response -eq "S" -or $response -eq "s") {
    Write-Host "`n  Enviando mensaje de prueba..." -ForegroundColor Cyan
    
    $testMessage = @{
        UserId = 1
        OrderId = 999
        EmailTo = "test@example.com"
        Subject = "Test DLQ"
        Body = "Mensaje de prueba para verificar DLQ"
        Template = "Default"
    } | ConvertTo-Json -Compress
    
    docker exec $ContainerName awslocal sqs send-message `
        --queue-url $mainQueueUrl `
        --message-body $testMessage | Out-Null
    
    Write-Host "  ✅ Mensaje enviado a cola principal" -ForegroundColor Green
    Write-Host "  ⏳ Esperando 5 segundos para procesamiento..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    
    # Verificar si Lambda procesó
    $newMsgCount = (docker exec $ContainerName awslocal sqs get-queue-attributes `
        --queue-url $mainQueueUrl `
        --attribute-names ApproximateNumberOfMessages `
        --query 'Attributes.ApproximateNumberOfMessages' `
        --output text).Trim()
    
    Write-Host "  Mensajes en cola principal: $newMsgCount" -ForegroundColor Gray
    
    if ($newMsgCount -gt 0) {
        Write-Host "  ⚠️ Mensaje NO fue procesado - Lambda no se invocó" -ForegroundColor Red
        Write-Host "     Verificar que NotificationService esté CAÍDO para test" -ForegroundColor Yellow
    } else {
        Write-Host "  ✅ Mensaje procesado (o en proceso)" -ForegroundColor Green
    }
}

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    RESUMEN DE DIAGNÓSTICO                      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`n💡 CAUSAS COMUNES DE DLQ VACÍA:" -ForegroundColor Yellow
Write-Host "  1. Cola principal sin mensajes → Lambda nunca se invoca" -ForegroundColor Gray
Write-Host "  2. Event Source Mapping deshabilitado → Lambda no se invoca" -ForegroundColor Gray
Write-Host "  3. Event Source Mapping sin DLQ configurada → Mensajes no van a DLQ" -ForegroundColor Gray
Write-Host "  4. Lambda completa exitosamente → No falla, no va a DLQ" -ForegroundColor Gray
Write-Host "  5. NotificationService está UP → Lambda tiene éxito, no falla" -ForegroundColor Gray
Write-Host "  6. Tiempo insuficiente → SQS tarda 7-10 min en mover a DLQ" -ForegroundColor Gray

Write-Host "`n🔧 SOLUCIÓN SEGÚN PROBLEMA IDENTIFICADO:" -ForegroundColor Yellow
Write-Host "  • Sin mensajes en cola → Ejecutar Test-Lambdas-Resilience.ps1" -ForegroundColor Gray
Write-Host "  • Mapping sin DLQ → Ejecutar Deploy-All-Lambdas-v2.ps1" -ForegroundColor Gray
Write-Host "  • NotificationService UP → Detenerlo: docker stop notificationservice" -ForegroundColor Gray
Write-Host "  • Lambda no invocada → Revisar event source mapping" -ForegroundColor Gray