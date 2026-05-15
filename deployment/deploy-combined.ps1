param(
    [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"

function Import-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ".env file not found at $Path"
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            return
        }

        $index = $line.IndexOf("=")
        if ($index -lt 1) {
            return
        }

        $name = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1).Trim()
        $value = $value.Trim('"').Trim("'")
        Set-Item -Path "Env:$name" -Value $value
    }
}

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found."
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$envFile = Join-Path $projectRoot ".env"

Write-Host "Deploying Content Creation Studio to Cloud Run"
Write-Host "=============================================="
Write-Host ""

Require-Command gcloud
Import-DotEnv -Path $envFile

$project = $env:GOOGLE_CLOUD_PROJECT
if ([string]::IsNullOrWhiteSpace($project)) {
    throw "GOOGLE_CLOUD_PROJECT is not set in .env"
}

$region = if ($env:GOOGLE_CLOUD_LOCATION) { $env:GOOGLE_CLOUD_LOCATION } else { "us-central1" }
$serviceName = if ($env:SERVICE_NAME) { $env:SERVICE_NAME } else { "content-studio" }
$repositoryName = if ($env:ARTIFACT_REPOSITORY_NAME) { $env:ARTIFACT_REPOSITORY_NAME } else { "content-studio" }
$useArtifactRegistry = if ($env:USE_ARTIFACT_REGISTRY) { $env:USE_ARTIFACT_REGISTRY } else { "true" }

if ($useArtifactRegistry -eq "true") {
    $imageName = "$region-docker.pkg.dev/$project/$repositoryName/$serviceName"
    $registryType = "Artifact Registry"
} else {
    $imageName = "gcr.io/$project/$serviceName"
    $registryType = "Container Registry"
}

Write-Host "Configuration:"
Write-Host "  Project: $project"
Write-Host "  Region: $region"
Write-Host "  Service Name: $serviceName"
Write-Host "  Registry: $registryType"
Write-Host "  Image: $imageName"
Write-Host "  Agent Resource: $(if ($env:AGENT_ENGINE_RESOURCE_NAME) { 'Configured' } else { 'Not configured' })"
Write-Host ""

if (-not $AutoApprove) {
    $answer = Read-Host "Deploy to Cloud Run? (y/n)"
    if ($answer -notmatch "^[Yy]$") {
        Write-Host "Deployment cancelled."
        exit 0
    }
}

Push-Location $projectRoot
try {
    Write-Host ""
    Write-Host "Step 1/4: Preparing Google Cloud project"
    Invoke-Checked gcloud config set project $project

    if ($useArtifactRegistry -eq "true") {
        & gcloud artifacts repositories describe $repositoryName --location=$region --project=$project *> $null
        if ($LASTEXITCODE -ne 0) {
            Invoke-Checked gcloud artifacts repositories create $repositoryName `
                --repository-format=docker `
                --location=$region `
                --description="Docker repository for Content Creation Studio" `
                --project=$project
        }
    }

    Write-Host ""
    Write-Host "Step 2/4: Building and pushing image via Cloud Build"
    Invoke-Checked gcloud builds submit `
        --tag $imageName `
        --machine-type=e2-highcpu-8 `
        --project=$project `
        .

    Write-Host ""
    Write-Host "Step 3/4: Deploying to Cloud Run"
    $serviceAccount = if ($env:SERVICE_ACCOUNT_EMAIL) {
        $env:SERVICE_ACCOUNT_EMAIL
    } else {
        "content-studio-sa@$project.iam.gserviceaccount.com"
    }

    $envVars = @(
        "GOOGLE_CLOUD_PROJECT=$project",
        "GOOGLE_CLOUD_LOCATION=$region",
        "GOOGLE_GENAI_USE_VERTEXAI=$(if ($env:GOOGLE_GENAI_USE_VERTEXAI) { $env:GOOGLE_GENAI_USE_VERTEXAI } else { '1' })"
    )

    if ($env:AGENT_ENGINE_RESOURCE_NAME) {
        $envVars += "AGENT_RESOURCE_NAME=$($env:AGENT_ENGINE_RESOURCE_NAME)"
        $envVars += "AGENT_ENGINE_RESOURCE_NAME=$($env:AGENT_ENGINE_RESOURCE_NAME)"
    }

    if ($env:GEMINI_MODEL) {
        $envVars += "GEMINI_MODEL=$($env:GEMINI_MODEL)"
    }

    if ($env:MAX_IMPROVEMENT_ITERATIONS) {
        $envVars += "MAX_IMPROVEMENT_ITERATIONS=$($env:MAX_IMPROVEMENT_ITERATIONS)"
    }

    if ($env:GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY) {
        $envVars += "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=$($env:GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY)"
    }

    if ($env:OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED) {
        $envVars += "OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=$($env:OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED)"
    }

    if ($env:OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT) {
        $envVars += "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=$($env:OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT)"
    }

    if ($env:ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS) {
        $envVars += "ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=$($env:ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS)"
    }

    $envVarsCsv = [string]::Join(",", $envVars)

    Invoke-Checked gcloud run deploy $serviceName `
        --image $imageName `
        --platform managed `
        --region $region `
        --project $project `
        --allow-unauthenticated `
        --port 8080 `
        --memory 2Gi `
        --cpu 2 `
        --timeout 3600 `
        --max-instances 10 `
        --min-instances 0 `
        --service-account $serviceAccount `
        --set-env-vars $envVarsCsv

    Write-Host ""
    Write-Host "Step 4/4: Retrieving and checking service URL"
    $serviceUrl = (& gcloud run services describe $serviceName --region $region --project $project --format "value(status.url)").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serviceUrl)) {
        throw "Could not read Cloud Run service URL."
    }

    try {
        Invoke-WebRequest -Uri "$serviceUrl/health" -UseBasicParsing -TimeoutSec 30 | Out-Null
        Write-Host "Health check passed"
    } catch {
        Write-Host "Health check did not pass yet. Check Cloud Run logs if it persists."
    }

    Write-Host ""
    Write-Host "Deployment complete."
    Write-Host "Service URL: $serviceUrl"
    Write-Host "Logs: gcloud run services logs read $serviceName --region $region --project $project"
} finally {
    Pop-Location
}
