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

Write-Host "Content Creation Studio: full GCP deployment"
Write-Host "============================================="
Write-Host ""

Require-Command gcloud

if (-not (Test-Path -LiteralPath $envFile)) {
    throw ".env file not found. Copy .env.example to .env and fill in your Google Cloud project settings."
}

Push-Location $projectRoot
try {
    Write-Host "Step 1/3: Preparing Google Cloud resources"
    & "$scriptDir\setup_gcp.ps1" -AutoApprove:$AutoApprove
    if ($LASTEXITCODE -ne 0) {
        throw "GCP setup failed."
    }

    Import-DotEnv -Path $envFile

    Write-Host ""
    Write-Host "Step 2/3: Preparing Vertex AI Agent Engine"
    if ($env:AGENT_ENGINE_RESOURCE_NAME) {
        Write-Host "Agent Engine resource is already configured; skipping agent deployment."
    } else {
        & gcloud auth application-default print-access-token *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Application Default Credentials are not configured. Run: gcloud auth application-default login"
        }

        if (Get-Command uv -ErrorAction SilentlyContinue) {
            Invoke-Checked uv run python deployment/deploy.py --action deploy
        } else {
            Invoke-Checked python deployment/deploy.py --action deploy
        }

        Import-DotEnv -Path $envFile
    }

    if (-not $env:AGENT_ENGINE_RESOURCE_NAME) {
        throw "Agent Engine deployment did not populate AGENT_ENGINE_RESOURCE_NAME."
    }

    Write-Host ""
    Write-Host "Step 3/3: Deploying frontend + backend to Cloud Run"
    & "$scriptDir\deploy-combined.ps1" -AutoApprove:$AutoApprove
    if ($LASTEXITCODE -ne 0) {
        throw "Cloud Run deployment failed."
    }

    Write-Host ""
    Write-Host "Full GCP deployment finished."
} finally {
    Pop-Location
}
