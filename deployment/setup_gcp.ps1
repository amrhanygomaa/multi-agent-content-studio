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

function Grant-ProjectRole {
    param(
        [Parameter(Mandatory = $true)][string]$Member,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Project
    )

    Write-Host "  - Granting $Role to $Member..."
    Invoke-Checked gcloud projects add-iam-policy-binding $Project `
        --member=$Member `
        --role=$Role `
        --condition=None `
        --quiet
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$envFile = Join-Path $projectRoot ".env"

Write-Host "=========================================="
Write-Host "  GCP Setup for Content Creation Studio"
Write-Host "=========================================="
Write-Host ""

Require-Command gcloud
Require-Command gsutil
Import-DotEnv -Path $envFile

$project = $env:GOOGLE_CLOUD_PROJECT
if ([string]::IsNullOrWhiteSpace($project)) {
    throw "GOOGLE_CLOUD_PROJECT is not set in .env"
}

$region = if ($env:GOOGLE_CLOUD_LOCATION) { $env:GOOGLE_CLOUD_LOCATION } else { "us-central1" }
$serviceAccountName = if ($env:SERVICE_ACCOUNT_NAME) { $env:SERVICE_ACCOUNT_NAME } else { "content-studio-sa" }
$serviceAccountEmail = "$serviceAccountName@$project.iam.gserviceaccount.com"
$repositoryName = if ($env:ARTIFACT_REPOSITORY_NAME) { $env:ARTIFACT_REPOSITORY_NAME } else { "content-studio" }

Write-Host "Configuration:"
Write-Host "   Project: $project"
Write-Host "   Region: $region"
Write-Host "   Service Account: $serviceAccountEmail"
Write-Host ""

if (-not $AutoApprove) {
    $answer = Read-Host "Proceed with GCP setup? (y/n)"
    if ($answer -notmatch "^[Yy]$") {
        Write-Host "Setup cancelled."
        exit 0
    }
}

Write-Host ""
Write-Host "Step 1: Set default project"
Invoke-Checked gcloud config set project $project

$projectNumber = (& gcloud projects describe $project --format="value(projectNumber)").Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($projectNumber)) {
    throw "Could not read project number for $project"
}

$activeAccount = (& gcloud auth list --filter=status:ACTIVE --format="value(account)" | Select-Object -First 1)

Write-Host ""
Write-Host "Step 2: Enable required APIs"
$requiredApis = @(
    "aiplatform.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "logging.googleapis.com"
)

$optionalApis = @(
    "telemetry.googleapis.com",
    "cloudtrace.googleapis.com",
    "apphub.googleapis.com",
    "apptopology.googleapis.com",
    "observability.googleapis.com"
)

foreach ($api in $requiredApis) {
    Write-Host "  - Enabling $api..."
    Invoke-Checked gcloud services enable $api --project=$project
}

foreach ($api in $optionalApis) {
    Write-Host "  - Enabling optional $api..."
    & gcloud services enable $api --project=$project
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    Optional API $api could not be enabled; continuing."
    }
}

Write-Host ""
Write-Host "Step 3: Create Artifact Registry repository"
& gcloud artifacts repositories describe $repositoryName --location=$region --project=$project *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Artifact Registry repository '$repositoryName' already exists"
} else {
    Invoke-Checked gcloud artifacts repositories create $repositoryName `
        --repository-format=docker `
        --location=$region `
        --description="Docker repository for Content Creation Studio" `
        --project=$project
}

Write-Host ""
Write-Host "Step 4: Configure Docker authentication"
Invoke-Checked gcloud auth configure-docker "$region-docker.pkg.dev" --quiet
Invoke-Checked gcloud auth configure-docker gcr.io --quiet

Write-Host ""
Write-Host "Step 5: Create Cloud Run service account"
& gcloud iam service-accounts describe $serviceAccountEmail --project=$project *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Service account '$serviceAccountName' already exists"
} else {
    Invoke-Checked gcloud iam service-accounts create $serviceAccountName `
        --display-name="Content Creation Studio Service Account" `
        --description="Service account for Content Creation Studio applications" `
        --project=$project
    Start-Sleep -Seconds 10
}

Write-Host ""
Write-Host "Step 6: Grant runtime IAM roles"
$runtimeRoles = @(
    "roles/aiplatform.user",
    "roles/run.invoker",
    "roles/storage.objectViewer",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/artifactregistry.reader"
)

$optionalRuntimeRoles = @(
    "roles/telemetry.tracesWriter"
)

foreach ($role in $runtimeRoles) {
    Grant-ProjectRole -Member "serviceAccount:$serviceAccountEmail" -Role $role -Project $project
}

foreach ($role in $optionalRuntimeRoles) {
    try {
        Grant-ProjectRole -Member "serviceAccount:$serviceAccountEmail" -Role $role -Project $project
    } catch {
        Write-Host "    Optional role $role could not be granted; continuing."
    }
}

if (-not [string]::IsNullOrWhiteSpace($activeAccount)) {
    if ($activeAccount -like "*gserviceaccount.com") {
        $activeMember = "serviceAccount:$activeAccount"
    } else {
        $activeMember = "user:$activeAccount"
    }

    Write-Host ""
    Write-Host "Granting Cloud Run deployer permission to active account..."
    & gcloud iam service-accounts add-iam-policy-binding $serviceAccountEmail `
        --member=$activeMember `
        --role=roles/iam.serviceAccountUser `
        --project=$project `
        --quiet *> $null
}

Write-Host ""
Write-Host "Step 7: Grant Cloud Build IAM roles"
$buildRoles = @(
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
    "roles/storage.objectViewer"
)

$buildServiceAccounts = @(
    "$projectNumber@cloudbuild.gserviceaccount.com",
    "$projectNumber-compute@developer.gserviceaccount.com"
)

foreach ($buildSa in $buildServiceAccounts) {
    & gcloud iam service-accounts describe $buildSa --project=$project *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Skipping missing Cloud Build service account: $buildSa"
        continue
    }

    Write-Host "Granting roles to Cloud Build service account: $buildSa"
    foreach ($role in $buildRoles) {
        Grant-ProjectRole -Member "serviceAccount:$buildSa" -Role $role -Project $project
    }
}

Write-Host ""
Write-Host "Step 8: Create Cloud Storage bucket"
if ($env:GOOGLE_CLOUD_STORAGE_BUCKET) {
    $bucketName = $env:GOOGLE_CLOUD_STORAGE_BUCKET -replace "^gs://", ""
} else {
    $bucketName = "$project-content-studio"
}

& gsutil ls -b "gs://$bucketName" *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Storage bucket 'gs://$bucketName' already exists"
} else {
    Invoke-Checked gcloud storage buckets create "gs://$bucketName" `
        --location=$region `
        --project=$project
}

$envContent = Get-Content -LiteralPath $envFile -Raw
if ($envContent -notmatch "(?m)^GOOGLE_CLOUD_STORAGE_BUCKET=") {
    Add-Content -LiteralPath $envFile -Value "GOOGLE_CLOUD_STORAGE_BUCKET=gs://$bucketName"
    Write-Host "Updated .env with GOOGLE_CLOUD_STORAGE_BUCKET"
}

Write-Host ""
Write-Host "Setup complete."
Write-Host "Project: $project"
Write-Host "Region: $region"
Write-Host "Artifact Registry: $region-docker.pkg.dev/$project/$repositoryName"
Write-Host "Cloud Run Service Account: $serviceAccountEmail"
Write-Host "Storage Bucket: gs://$bucketName"
