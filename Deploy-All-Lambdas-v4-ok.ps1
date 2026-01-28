#Requires -Version 7

<#
.SYNOPSIS
    Despliega las 2 Lambda Functions de Semana 2 (CON POLLY) en LocalStack
.DESCRIPTION
    Script para redesplegar ImageProcessor y EmailBatch con resiliencia Polly
    CAMBIOS EN SEMANA 2:
    - Timeout incrementado: 30s → 60s (permite reintentos)
    - Variables de ambiente para Polly (retry, timeout, circuit breaker)
    - Reports NO se redesplega (sin cambios en Semana 2 FASE 1)
.NOTES
    - Asegúrate de que LocalStack esté ejecutándose (docker-compose up -d)
    - Los buckets S3 ya deben existir de Semana 1
    - Este script solo redesplega ImageProcessor y EmailBatch
    
    ⚠️ IMPORTANTE: Ejecutar este script desde la RAÍZ del proyecto:
    
    CORRECTO:
    PS C:\Users\nayah\source\repos\M3Sem1Lambdas> .\Deployment-Guides\Deploy-All-Lambdas-v2.ps1
    
    INCORRECTO:
    PS C:\Users\nayah\source\repos\M3Sem1Lambdas\Deployment-Guides> .\Deploy-All-Lambdas-v2.ps1
    
    [1/7] Verificar LocalStack
    [2/7] Verificar buckets S3 existentes
    [3/7] Verificar IAM role
    [4/7] Redesplegar ImageProcessor CON POLLY
    [5/7] Redesplegar EmailBatch CON POLLY
    [6/7] Listar Lambdas
    [7/7] Mostrar resumen
#>

param(
    [switch]$SkipBuild,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     DEPLOYMENT SEMANA 2 - LAMBDAS CON POLLY EN LOCALSTACK     ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Configuración
$LocalStackEndpoint = "http://localhost:4566"
$Region = "us-east-1"
$ContainerName = "localstack-aws"

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# [1/7] VERIFICAR LOCALSTACK
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[1/7] 🔍 Verificando LocalStack..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "$LocalStackEndpoint/_localstack/health" -UseBasicParsing
    Write-Host "✅ LocalStack está disponible" -ForegroundColor Green
} catch {
    Write-Host "❌ LocalStack no está disponible. Ejecuta: docker-compose up -d" -ForegroundColor Red
    exit 1
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# [2/7] VERIFICAR BUCKETS S3 EXISTENTES
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[2/7] 🪣 Verificando buckets S3..." -ForegroundColor Yellow

$requiredBuckets = @(
    "product-images",
    "product-images-processed",
    "reports-generated"
)

foreach ($bucket in $requiredBuckets) {
    $bucketExists = docker exec $ContainerName awslocal s3 ls s3://$bucket 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Bucket '$bucket' existe" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️ Bucket '$bucket' no existe - creándolo..." -ForegroundColor Yellow
        docker exec $ContainerName awslocal s3 mb s3://$bucket | Out-Null
        Write-Host "  ✓ Bucket '$bucket' creado" -ForegroundColor Green
    }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# [3/7] VERIFICAR IAM ROLE
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[3/7] 🔐 Verificando rol IAM..." -ForegroundColor Yellow

$roleName = "lambda-execution-role"
$roleArn = "arn:aws:iam::000000000000:role/$roleName"

$roleExists = docker exec $ContainerName awslocal iam get-role --role-name $roleName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ⚠️ Rol IAM no existe - creándolo..." -ForegroundColor Yellow
    
    $trustPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
"@
    
    docker exec $ContainerName awslocal iam create-role `
        --role-name $roleName `
        --assume-role-policy-document $trustPolicy | Out-Null
    
    Write-Host "  ✓ Rol IAM creado" -ForegroundColor Green
} else {
    Write-Host "  ✓ Rol IAM existe" -ForegroundColor Green
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FUNCIONES AUXILIARES
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Build-LambdaPackage {
    param(
        [string]$ProjectPath,
        [string]$FunctionName
    )

    Write-Host "  🔨 Compilando $FunctionName..." -ForegroundColor Yellow
    
    Push-Location $ProjectPath
    try {
        # Limpiar build anterior
        if (Test-Path ./publish) {
            Remove-Item -Recurse -Force ./publish
        }

        # Compilar (mismo comando que Semana 1)
        if ($Verbose) {
            dotnet publish -c Release -r linux-x64 --self-contained false -o ./publish
        } else {
            dotnet publish -c Release -r linux-x64 --self-contained false -o ./publish | Out-Null
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Error compilando $FunctionName"
        }

        # Crear ZIP
        $zipFileName = "$FunctionName.zip"
        $zipPath = Join-Path (Get-Location) $zipFileName
        
        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force
        }

        Compress-Archive -Path ./publish/* -DestinationPath $zipPath -Force
        
        if (-not (Test-Path $zipPath)) {
            throw "ZIP no creado correctamente para $FunctionName"
        }

        Write-Host "  ✅ Compilación exitosa: $zipPath" -ForegroundColor Green

        # Copiar ZIP al contenedor (mismo método que Semana 1)
        Write-Host "  📤 Copiando al contenedor..." -ForegroundColor Yellow
        docker cp $zipPath ${ContainerName}:/tmp/$zipFileName
        
        if ($LASTEXITCODE -ne 0) {
            throw "Error copiando ZIP al contenedor"
        }

        # Verificar que el archivo llegó
        $fileCheck = docker exec $ContainerName ls -la /tmp/$zipFileName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "ZIP no encontrado en contenedor: $fileCheck"
        }

        Write-Host "  ✅ ZIP copiado al contenedor: /tmp/$zipFileName" -ForegroundColor Green

        # Limpiar ZIP local
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        return $zipFileName

    } finally {
        Pop-Location
    }
}

function Deploy-Lambda {
    param(
        [string]$FunctionName,
        [string]$ZipFileName,
        [string]$Handler,
        [hashtable]$Environment,
        [int]$Memory = 512,
        [int]$Timeout = 60,
        [string]$Description
    )

    # Convertir environment a JSON (mismo método que Semana 1)
    $envVarsJson = '{"Variables":{'
    $first = $true
    foreach ($key in $Environment.Keys) {
        if (-not $first) { $envVarsJson += "," }
        $envVarsJson += "`"$key`":`"$($Environment[$key])`""
        $first = $false
    }
    $envVarsJson += '}}'

    # Verificar si Lambda existe
    Write-Host "  🔍 Verificando si Lambda existe..." -ForegroundColor Yellow
    
    $checkResult = docker exec $ContainerName awslocal lambda get-function --function-name $FunctionName 2>&1
    $lambdaExists = $LASTEXITCODE -eq 0

    if ($lambdaExists) {
        Write-Host "  🔄 Lambda existente, actualizando código..." -ForegroundColor Yellow
        
        docker exec $ContainerName awslocal lambda update-function-code `
            --function-name $FunctionName `
            --zip-file fileb:///tmp/$ZipFileName | Out-Null

        # Actualizar configuración
        docker exec $ContainerName awslocal lambda update-function-configuration `
            --function-name $FunctionName `
            --environment $envVarsJson `
            --timeout $Timeout `
            --memory-size $Memory | Out-Null

        Write-Host "  ✅ Lambda actualizada" -ForegroundColor Green
    } else {
        Write-Host "  🆕 Creando nueva Lambda..." -ForegroundColor Yellow
        
        docker exec $ContainerName awslocal lambda create-function `
            --function-name $FunctionName `
            --runtime dotnet8 `
            --handler $Handler `
            --role arn:aws:iam::000000000000:role/lambda-execution-role `
            --zip-file fileb:///tmp/$ZipFileName `
            --timeout $Timeout `
            --memory-size $Memory `
            --environment $envVarsJson `
            --description "$Description" | Out-Null

        Write-Host "  ✅ Lambda creada" -ForegroundColor Green
    }

    # Esperar a que esté activa
    Start-Sleep -Seconds 2
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# [4/7] REDESPLEGAR IMAGEPROCESSOR CON POLLY
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[4/7] 📸 Redesplegando ImageProcessor Lambda (CON POLLY)..." -ForegroundColor Cyan

if (-not $SkipBuild) {
    $imageZip = Build-LambdaPackage -ProjectPath "ImageProcessor.Lambda" -FunctionName "ImageProcessorFunction"
} else {
    $imageZip = "ImageProcessorFunction.zip"
}

Deploy-Lambda `
    -FunctionName "ImageProcessorFunction" `
    -ZipFileName $imageZip `
    -Handler "ImageProcessor.Lambda::ImageProcessor.Lambda.Function::FunctionHandler" `
    -Environment @{
        S3_ENDPOINT = "http://localstack:4566"
        PRODUCT_SERVICE_URL = "http://productservice:7001"
        OUTPUT_BUCKET = "product-images-processed"
        RETRY_MAX_ATTEMPTS = "3"
        RETRY_DELAY_SECONDS = "1"
        TIMEOUT_SECONDS = "10"
        FALLBACK_ENABLED = "true"
    } `
    -Memory 512 `
    -Timeout 60 `
    -Description "Procesa imágenes S3 con Polly (Retry + Timeout + Fallback)"

Write-Host "  ℹ️ SEMANA 2: Timeout 30s → 60s, Variables Polly agregadas" -ForegroundColor Cyan

# Event source mapping S3 (debe existir de Semana 1)
Write-Host "  🔗 Verificando trigger S3..." -ForegroundColor Yellow
$s3NotificationExists = docker exec $ContainerName awslocal s3api get-bucket-notification-configuration `
    --bucket product-images 2>&1

if ($LASTEXITCODE -eq 0 -and $s3NotificationExists -match "ImageProcessorFunction") {
    Write-Host "  ✓ Trigger S3 ya configurado" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ Configurando trigger S3..." -ForegroundColor Yellow
    
    $s3NotificationConfig = @"
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "arn:aws:lambda:$Region:000000000000:function:ImageProcessorFunction",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "prefix", "Value": "products/"},
            {"Name": "suffix", "Value": ".jpg"}
          ]
        }
      }
    }
  ]
}
"@
    
    docker exec $ContainerName awslocal s3api put-bucket-notification-configuration `
        --bucket product-images `
        --notification-configuration $s3NotificationConfig | Out-Null
    
    Write-Host "  ✓ Trigger S3 configurado" -ForegroundColor Green
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# [5/7] REDESPLEGAR EMAILBATCH CON POLLY
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[5/7] 📧 Redesplegando EmailBatch Lambda (CON POLLY)..." -ForegroundColor Cyan

if (-not $SkipBuild) {
    $emailZip = Build-LambdaPackage -ProjectPath "EmailBatch.Lambda" -FunctionName "EmailBatchProcessorFunction"
} else {
    $emailZip = "EmailBatchProcessorFunction.zip"
}

Deploy-Lambda `
    -FunctionName "EmailBatchProcessorFunction" `
    -ZipFileName $emailZip `
    -Handler "EmailBatch.Lambda::EmailBatch.Lambda.Function::FunctionHandler" `
    -Environment @{
        NOTIFICATION_SERVICE_URL = "http://notificationservice:7005"
        CIRCUIT_FAILURE_RATIO = "0.5"
        CIRCUIT_SAMPLING_DURATION_SECONDS = "30"
        CIRCUIT_BREAK_DURATION_SECONDS = "30"
        RETRY_MAX_ATTEMPTS = "2"
        TIMEOUT_SECONDS = "10"
    } `
    -Memory 256 `
    -Timeout 60 `
    -Description "Procesa emails SQS con Polly (Circuit Breaker + Retry + Timeout)"

Write-Host "  ℹ️ SEMANA 2: Timeout 30s → 60s, Circuit Breaker agregado" -ForegroundColor Cyan

# Event source mapping SQS - SIEMPRE con DLQ
Write-Host "  🔗 Verificando trigger SQS y DLQ..." -ForegroundColor Yellow

$queueUrl = "http://localhost:4566/000000000000/email-notifications-queue"
$queueArn = docker exec $ContainerName awslocal sqs get-queue-attributes `
    --queue-url $queueUrl `
    --attribute-names QueueArn `
    --query 'Attributes.QueueArn' `
    --output text

$queueArn = $queueArn.Trim()

# ✅ PASO 1: Crear DLQ si no existe
$dlqName = "email-notifications-dlq"
$dlqUrl = docker exec $ContainerName awslocal sqs get-queue-url --queue-name $dlqName --query 'QueueUrl' --output text 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "     → Creando DLQ: $dlqName" -ForegroundColor Gray
    docker exec $ContainerName awslocal sqs create-queue --queue-name $dlqName | Out-Null
    $dlqUrl = docker exec $ContainerName awslocal sqs get-queue-url --queue-name $dlqName --query 'QueueUrl' --output text
}

# Obtener ARN de la DLQ
$dlqArn = docker exec $ContainerName awslocal sqs get-queue-attributes `
    --queue-url $dlqUrl.Trim() `
    --attribute-names QueueArn `
    --query 'Attributes.QueueArn' `
    --output text

$dlqArn = $dlqArn.Trim()

# ✅ PASO 2: Verificar si event source mapping existe
$existingMappings = docker exec $ContainerName awslocal lambda list-event-source-mappings `
    --function-name EmailBatchProcessorFunction `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    $mappingsObj = $existingMappings | ConvertFrom-Json
    
    if ($mappingsObj.EventSourceMappings.Count -gt 0) {
        # Mapping existe - ACTUALIZAR con DLQ si no la tiene
        $mapping = $mappingsObj.EventSourceMappings[0]
        $mappingUuid = $mapping.UUID
        $hasDestinationConfig = $null -ne $mapping.DestinationConfig -and $null -ne $mapping.DestinationConfig.OnFailure
        
        if (-not $hasDestinationConfig) {
            Write-Host "     → Actualizando mapping existente con DLQ..." -ForegroundColor Yellow
            
            docker exec $ContainerName awslocal lambda update-event-source-mapping `
                --uuid $mappingUuid `
                --destination-config "{`"OnFailure`":{`"Destination`":`"$dlqArn`"}}" `
                --output json 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Mapping actualizado con DLQ" -ForegroundColor Green
            } else {
                Write-Host "  ⚠️ No se pudo actualizar, recreando mapping..." -ForegroundColor Yellow
                
                # Eliminar y recrear
                docker exec $ContainerName awslocal lambda delete-event-source-mapping --uuid $mappingUuid 2>&1 | Out-Null
                Start-Sleep -Seconds 2
                
                docker exec $ContainerName awslocal lambda create-event-source-mapping `
                    --function-name EmailBatchProcessorFunction `
                    --event-source-arn $queueArn `
                    --batch-size 10 `
                    --enabled `
                    --destination-config "{`"OnFailure`":{`"Destination`":`"$dlqArn`"}}" | Out-Null
                
                Write-Host "  ✓ Mapping recreado con DLQ" -ForegroundColor Green
            }
        } else {
            Write-Host "  ✓ Trigger SQS ya tiene DLQ configurada" -ForegroundColor Green
        }
    } else {
        # Mapping NO existe - CREAR con DLQ
        Write-Host "     → Creando mapping con DLQ..." -ForegroundColor Yellow
        
        docker exec $ContainerName awslocal lambda create-event-source-mapping `
            --function-name EmailBatchProcessorFunction `
            --event-source-arn $queueArn `
            --batch-size 10 `
            --enabled `
            --destination-config "{`"OnFailure`":{`"Destination`":`"$dlqArn`"}}" | Out-Null
        
        Write-Host "  ✓ Trigger SQS configurado con DLQ ($dlqName)" -ForegroundColor Green
    }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# [6/7] VERIFICACIÓN
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║          ✅ DEPLOYMENT SEMANA 2 COMPLETADO EXITOSAMENTE        ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n[6/7] 📋 Lambdas Desplegadas con Polly:" -ForegroundColor Yellow
docker exec $ContainerName awslocal lambda list-functions `
    --query 'Functions[].[FunctionName, Runtime, Timeout, MemorySize]' `
    --output table

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# [7/7] RESUMEN
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[7/7] 📊 Resumen de Configuración SEMANA 2:" -ForegroundColor Yellow

Write-Host "`n  📸 ImageProcessor (CON POLLY):" -ForegroundColor Cyan
Write-Host "     - Timeout: 60s (antes 30s)" -ForegroundColor White
Write-Host "     - Polly: Retry (3x) + Timeout (10s) + Fallback" -ForegroundColor White
Write-Host "     - Variables:" -ForegroundColor White
Write-Host "       * RETRY_MAX_ATTEMPTS = 3" -ForegroundColor Gray
Write-Host "       * RETRY_DELAY_SECONDS = 1" -ForegroundColor Gray
Write-Host "       * TIMEOUT_SECONDS = 10" -ForegroundColor Gray
Write-Host "       * FALLBACK_ENABLED = true" -ForegroundColor Gray

Write-Host "`n  📧 EmailBatch (CON POLLY):" -ForegroundColor Cyan
Write-Host "     - Timeout: 60s (antes 30s)" -ForegroundColor White
Write-Host "     - Polly: Circuit Breaker + Retry (2x) + Timeout (10s)" -ForegroundColor White
Write-Host "     - Variables:" -ForegroundColor White
Write-Host "       * CIRCUIT_FAILURE_RATIO = 0.5" -ForegroundColor Gray
Write-Host "       * CIRCUIT_SAMPLING_DURATION_SECONDS = 30" -ForegroundColor Gray
Write-Host "       * CIRCUIT_BREAK_DURATION_SECONDS = 30" -ForegroundColor Gray
Write-Host "       * RETRY_MAX_ATTEMPTS = 2" -ForegroundColor Gray

Write-Host "`n  📊 Reports:" -ForegroundColor Cyan
Write-Host "     - Sin cambios en Semana 2 FASE 1" -ForegroundColor White

Write-Host "`n🎉 Las Lambdas con Polly están listas para probar resiliencia!" -ForegroundColor Green
Write-Host "💡 Ejecuta Test-Lambdas-Resilience.ps1 para probar retry y circuit breaker" -ForegroundColor Cyan