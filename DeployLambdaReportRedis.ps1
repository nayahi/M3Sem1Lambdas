#Requires -Version 7


<#
.SYNOPSIS
    Despliega las 3 Lambda Functions de Semana 1 en LocalStack
.DESCRIPTION
    Script para crear y configurar ImageProcessor, Reports y EmailBatch Lambdas
.NOTES
    - Asegúrate de que LocalStack esté ejecutándose (docker-compose up -d)
    - Los buckets S3 se crearán automáticamente si no existen
	
	[1/9] Verificar LocalStack
	[2/9] Crear buckets S3 (product-images, product-images-processed, reports-generated) ← NUEVO
	[3/9] Verificar/crear rol IAM
	[4/9] Desplegar ImageProcessor + configurar trigger S3
	[5/9] Desplegar Reports + configurar API Gateway
	[6/9] Desplegar EmailBatch + configurar event source mapping SQS
	[7/9] Listar Lambdas
	[8/9] Listar event source mappings
	[9/9] Mostrar resumen
#>

param(
    [switch]$SkipBuild,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     DEPLOYMENT DE LAMBDAS SEMANA 1 EN LOCALSTACK              ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Configuración
$LocalStackEndpoint = "http://localhost:4566"
$Region = "us-east-1"
$ContainerName = "localstack-aws"

# Verificar que LocalStack esté corriendo
Write-Host "`n[1/9] 🔍 Verificando LocalStack..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "$LocalStackEndpoint/_localstack/health" -UseBasicParsing
    Write-Host "✅ LocalStack está disponible" -ForegroundColor Green
} catch {
    Write-Host "❌ LocalStack no está disponible. Inicia LocalStack primero con docker-compose up -d" -ForegroundColor Red
    exit 1
}

# ✅ NUEVO: Verificar Redis
Write-Host "`n[2/8] 🔍 Verificando Redis..." -ForegroundColor Yellow
$redisCheck = docker exec $ContainerName redis-cli -h redis ping 2>&1
if ($LASTEXITCODE -eq 0 -and $redisCheck -match "PONG") {
    Write-Host "✅ Redis disponible y respondiendo" -ForegroundColor Green
} else {
    Write-Host "⚠️ Redis no disponible - Lambda funcionará sin caché" -ForegroundColor Yellow
}


# Crear buckets S3 si no existen
Write-Host "`n[2/9] 🪣 Verificando y creando buckets S3..." -ForegroundColor Yellow

function New-S3BucketIfNotExists {
    param([string]$BucketName)
    
    $checkBucket = docker exec $ContainerName awslocal s3 ls s3://$BucketName 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚙️ Creando bucket: $BucketName" -ForegroundColor Cyan
        docker exec $ContainerName awslocal s3 mb s3://$BucketName
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Bucket creado: $BucketName" -ForegroundColor Green
        } else {
            Write-Host "  ❌ Error creando bucket: $BucketName" -ForegroundColor Red
            throw "No se pudo crear el bucket $BucketName"
        }
    } else {
        Write-Host "  ✅ Bucket existente: $BucketName" -ForegroundColor Green
    }
}

# Crear los 3 buckets necesarios
New-S3BucketIfNotExists -BucketName "product-images"
New-S3BucketIfNotExists -BucketName "product-images-processed"
New-S3BucketIfNotExists -BucketName "reports-generated"

Write-Host "✅ Buckets S3 verificados/creados" -ForegroundColor Green

# Verificar rol IAM
Write-Host "`n[3/9] 🔐 Verificando rol IAM..." -ForegroundColor Yellow
$checkRole = docker exec $ContainerName awslocal iam get-role --role-name lambda-execution-role 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ⚙️ Creando rol lambda-execution-role..." -ForegroundColor Cyan
    docker exec $ContainerName awslocal iam create-role `
        --role-name lambda-execution-role `
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' | Out-Null
    
    docker exec $ContainerName awslocal iam attach-role-policy `
        --role-name lambda-execution-role `
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole | Out-Null
    
    Write-Host "  ✅ Rol IAM creado" -ForegroundColor Green
} else {
    Write-Host "  ✅ Rol IAM existente" -ForegroundColor Green
}

# Función para compilar y empaquetar Lambda
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

        # Compilar
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

        # Copiar ZIP al contenedor
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

# Función para crear/actualizar Lambda
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

    # Convertir environment a JSON
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
# 1. REPORTS LAMBDA
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n[5/9] 📊 Desplegando Reports Lambda..." -ForegroundColor Cyan

if (-not $SkipBuild) {
    $reportsZip = Build-LambdaPackage -ProjectPath "Reports.Lambda" -FunctionName "ReportsGeneratorFunction"
} else {
    $reportsZip = "ReportsGeneratorFunction.zip"
}

Deploy-Lambda `
    -FunctionName "ReportsGeneratorFunction" `
    -ZipFileName $reportsZip `
    -Handler "Reports.Lambda::Reports.Lambda.Function::FunctionHandler" `
    -Environment @{
        S3_ENDPOINT = "http://localstack:4566"
        SQL_CONNECTION_STRING = "Server=sqlserver,1433;User Id=sa;Password=Password123!;TrustServerCertificate=True;"
        REPORTS_BUCKET = "reports-generated"
		REDIS_ENDPOINT = "redis:6379"
    } `
    -Memory 1024 `
    -Timeout 120 `
    -Description "Genera reportes PDF on-demand consultando SQL Server"

# Configurar API Gateway
Write-Host "  🔗 Configurando API Gateway..." -ForegroundColor Yellow

# Verificar si API ya existe
$existingApis = docker exec $ContainerName awslocal apigateway get-rest-apis --query "items[?name=='ReportsAPI'].id" --output text 2>&1
if ($LASTEXITCODE -eq 0 -and $existingApis -and -not [string]::IsNullOrWhiteSpace($existingApis)) {
    $apiId = $existingApis.Trim()
    Write-Host "  ℹ️ API Gateway existente encontrado: $apiId" -ForegroundColor Cyan
} else {
    # Crear API Gateway
    $apiResponse = docker exec $ContainerName awslocal apigateway create-rest-api `
        --name "ReportsAPI" `
        --description "API for Reports Lambda" `
        --output json | ConvertFrom-Json
    
    $apiId = $apiResponse.id
    Write-Host "  ✅ API Gateway creado: $apiId" -ForegroundColor Green
}

# Obtener root resource ID
$rootResourceId = docker exec $ContainerName awslocal apigateway get-resources `
    --rest-api-id $apiId `
    --query "items[?path=='/'].id" `
    --output text

$rootResourceId = $rootResourceId.Trim()

# Crear recurso /reports (si no existe)
$reportsResourceId = docker exec $ContainerName awslocal apigateway get-resources `
    --rest-api-id $apiId `
    --query "items[?pathPart=='reports'].id" `
    --output text 2>&1

if (-not $reportsResourceId -or [string]::IsNullOrWhiteSpace($reportsResourceId) -or $reportsResourceId.Contains("None")) {
    $resourceResponse = docker exec $ContainerName awslocal apigateway create-resource `
        --rest-api-id $apiId `
        --parent-id $rootResourceId `
        --path-part "reports" `
        --output json | ConvertFrom-Json
    
    $reportsResourceId = $resourceResponse.id
    Write-Host "  ✅ Recurso /reports creado" -ForegroundColor Green
} else {
    $reportsResourceId = $reportsResourceId.Trim()
    Write-Host "  ℹ️ Recurso /reports existente: $reportsResourceId" -ForegroundColor Cyan
}

# Crear método GET (si no existe)
$methodExists = docker exec $ContainerName awslocal apigateway get-method `
    --rest-api-id $apiId `
    --resource-id $reportsResourceId `
    --http-method GET 2>&1

if ($LASTEXITCODE -ne 0) {
    docker exec $ContainerName awslocal apigateway put-method `
        --rest-api-id $apiId `
        --resource-id $reportsResourceId `
        --http-method GET `
        --authorization-type NONE | Out-Null
    
    Write-Host "  ✅ Método GET creado" -ForegroundColor Green
} else {
    Write-Host "  ℹ️ Método GET existente" -ForegroundColor Cyan
}

# Configurar integración con Lambda
$lambdaArn = "arn:aws:lambda:us-east-1:000000000000:function:ReportsGeneratorFunction"
$integrationUri = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/$lambdaArn/invocations"

docker exec $ContainerName awslocal apigateway put-integration `
    --rest-api-id $apiId `
    --resource-id $reportsResourceId `
    --http-method GET `
    --type AWS_PROXY `
    --integration-http-method POST `
    --uri $integrationUri | Out-Null

Write-Host "  ✅ Integración Lambda configurada" -ForegroundColor Green

# Dar permisos a API Gateway para invocar Lambda
docker exec $ContainerName awslocal lambda add-permission `
    --function-name ReportsGeneratorFunction `
    --statement-id apigateway-invoke `
    --action lambda:InvokeFunction `
    --principal apigateway.amazonaws.com `
    --source-arn "arn:aws:execute-api:us-east-1:000000000000:${apiId}/*/*" 2>&1 | Out-Null

# Desplegar API
docker exec $ContainerName awslocal apigateway create-deployment `
    --rest-api-id $apiId `
    --stage-name prod | Out-Null

$apiUrl = "http://localhost:4566/restapis/$apiId/prod/_user_request_/reports"
Write-Host "  ✅ API Gateway desplegado" -ForegroundColor Green
Write-Host "  🌐 URL: $apiUrl" -ForegroundColor Cyan


#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# VERIFICACIÓN FINAL
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║           ✅ DEPLOYMENT COMPLETADO EXITOSAMENTE                ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n[7/9] 📋 Lambdas Desplegadas:" -ForegroundColor Yellow
docker exec $ContainerName awslocal lambda list-functions `
    --query 'Functions[].[FunctionName, Runtime, Timeout, MemorySize]' `
    --output table

Write-Host "`n[8/9] 🔗 Event Source Mappings:" -ForegroundColor Yellow
docker exec $ContainerName awslocal lambda list-event-source-mappings `
    --query 'EventSourceMappings[].[FunctionArn, EventSourceArn, State]' `
    --output table

Write-Host "`n[9/9] 📊 Resumen de Configuración:" -ForegroundColor Yellow
Write-Host "`n  📊 Reports:" -ForegroundColor Cyan
Write-Host "     - Trigger: API Gateway" -ForegroundColor White
Write-Host "     - URL: $apiUrl" -ForegroundColor White
Write-Host "     - Parámetros: ?type=sales&startDate=2025-01-01&endDate=2025-01-31" -ForegroundColor White

Write-Host "`n🎉 Las Lambdas están listas para usar!" -ForegroundColor Green
Write-Host "💡 Ejecuta Test-Lambdas.ps1 para probar cada Lambda" -ForegroundColor Cyan