#!/bin/bash

# Google Cloud Platform setup for Content Creation Studio.
# Enables required APIs, creates Artifact Registry/GCS resources, and grants
# the IAM roles needed by Cloud Run, Agent Engine, and Cloud Build.

set -euo pipefail

echo "=========================================="
echo "  GCP Setup for Content Creation Studio"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

load_env() {
    if [ -f "$ENV_FILE" ]; then
        echo "Loading environment variables from $ENV_FILE..."
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    else
        echo "❌ Error: .env file not found at $ENV_FILE"
        exit 1
    fi
}

confirm() {
    if [ "${AUTO_APPROVE:-false}" = "true" ] || [ "${CI:-false}" = "true" ]; then
        echo "AUTO_APPROVE enabled; continuing."
        return
    fi

    read -p "Proceed with GCP setup? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "❌ Error: required command '$1' was not found"
        exit 1
    fi
}

grant_project_role() {
    local member="$1"
    local role="$2"

    echo "  - Granting $role to $member..."
    gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
        --member="$member" \
        --role="$role" \
        --condition=None \
        --quiet >/dev/null
}

load_env
require_command gcloud
require_command gsutil

if [ -z "${GOOGLE_CLOUD_PROJECT:-}" ]; then
    echo "❌ Error: GOOGLE_CLOUD_PROJECT not set"
    echo "Set it in .env file or export GOOGLE_CLOUD_PROJECT='your-project-id'"
    exit 1
fi

REGION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-content-studio-sa}"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com"
REPOSITORY_NAME="${ARTIFACT_REPOSITORY_NAME:-content-studio}"

echo "Configuration:"
echo "   Project: $GOOGLE_CLOUD_PROJECT"
echo "   Region: $REGION"
echo "   Service Account: $SERVICE_ACCOUNT_EMAIL"
echo ""

confirm

echo ""
echo "=========================================="
echo "Step 1: Set Default Project"
echo "=========================================="
echo ""

gcloud config set project "$GOOGLE_CLOUD_PROJECT"
echo "Default project set to: $GOOGLE_CLOUD_PROJECT"

PROJECT_NUMBER="$(gcloud projects describe "$GOOGLE_CLOUD_PROJECT" --format='value(projectNumber)')"
ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1 || true)"

echo ""
echo "=========================================="
echo "Step 2: Enable Required APIs"
echo "=========================================="
echo ""

REQUIRED_APIS=(
    "aiplatform.googleapis.com"
    "run.googleapis.com"
    "cloudbuild.googleapis.com"
    "artifactregistry.googleapis.com"
    "storage.googleapis.com"
    "iam.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "logging.googleapis.com"
)

OPTIONAL_APIS=(
    "telemetry.googleapis.com"
    "cloudtrace.googleapis.com"
    "apphub.googleapis.com"
    "apptopology.googleapis.com"
    "observability.googleapis.com"
)

echo "Enabling APIs (this may take a few minutes)..."
for api in "${REQUIRED_APIS[@]}"; do
    echo "  - Enabling $api..."
    gcloud services enable "$api" --project="$GOOGLE_CLOUD_PROJECT"
done

for api in "${OPTIONAL_APIS[@]}"; do
    echo "  - Enabling optional $api..."
    if ! gcloud services enable "$api" --project="$GOOGLE_CLOUD_PROJECT"; then
        echo "    ⚠️  Optional API $api could not be enabled; continuing."
    fi
done

echo "All APIs enabled successfully!"

echo ""
echo "=========================================="
echo "Step 3: Create Artifact Registry Repository"
echo "=========================================="
echo ""

if gcloud artifacts repositories describe "$REPOSITORY_NAME" \
    --location="$REGION" \
    --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
    echo "Artifact Registry repository '$REPOSITORY_NAME' already exists"
else
    echo "Creating Artifact Registry repository..."
    gcloud artifacts repositories create "$REPOSITORY_NAME" \
        --repository-format=docker \
        --location="$REGION" \
        --description="Docker repository for Content Creation Studio" \
        --project="$GOOGLE_CLOUD_PROJECT"
    echo "Artifact Registry repository created!"
fi

echo ""
echo "=========================================="
echo "Step 4: Configure Docker Authentication"
echo "=========================================="
echo ""

echo "Configuring Docker to authenticate with Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo ""
echo "Configuring Docker for legacy GCR if needed..."
gcloud auth configure-docker gcr.io --quiet

echo ""
echo "=========================================="
echo "Step 5: Create Cloud Run Service Account"
echo "=========================================="
echo ""

if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" \
    --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
    echo "Service account '$SERVICE_ACCOUNT_NAME' already exists"
else
    echo "Creating service account..."
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
        --display-name="Content Creation Studio Service Account" \
        --description="Service account for Content Creation Studio applications" \
        --project="$GOOGLE_CLOUD_PROJECT"
    echo "Service account created. Waiting for propagation..."
    sleep 10
fi

echo ""
echo "=========================================="
echo "Step 6: Grant Runtime IAM Roles"
echo "=========================================="
echo ""

RUNTIME_ROLES=(
    "roles/aiplatform.user"
    "roles/run.invoker"
    "roles/storage.objectViewer"
    "roles/logging.logWriter"
    "roles/monitoring.metricWriter"
    "roles/artifactregistry.reader"
)

OPTIONAL_RUNTIME_ROLES=(
    "roles/telemetry.tracesWriter"
)

echo "Granting roles to Cloud Run service account..."
for role in "${RUNTIME_ROLES[@]}"; do
    grant_project_role "serviceAccount:$SERVICE_ACCOUNT_EMAIL" "$role"
done

for role in "${OPTIONAL_RUNTIME_ROLES[@]}"; do
    if ! grant_project_role "serviceAccount:$SERVICE_ACCOUNT_EMAIL" "$role"; then
        echo "    ⚠️  Optional role $role could not be granted; continuing."
    fi
done

if [ -n "$ACTIVE_ACCOUNT" ]; then
    if [[ "$ACTIVE_ACCOUNT" == *"gserviceaccount.com" ]]; then
        ACTIVE_MEMBER="serviceAccount:$ACTIVE_ACCOUNT"
    else
        ACTIVE_MEMBER="user:$ACTIVE_ACCOUNT"
    fi

    echo ""
    echo "Granting Cloud Run deployer permission to active account..."
    gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
        --member="$ACTIVE_MEMBER" \
        --role="roles/iam.serviceAccountUser" \
        --project="$GOOGLE_CLOUD_PROJECT" \
        --quiet >/dev/null || true
fi

echo ""
echo "=========================================="
echo "Step 7: Grant Cloud Build IAM Roles"
echo "=========================================="
echo ""

BUILD_ROLES=(
    "roles/artifactregistry.writer"
    "roles/logging.logWriter"
    "roles/storage.objectViewer"
)

BUILD_SERVICE_ACCOUNTS=(
    "${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
    "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
)

for build_sa in "${BUILD_SERVICE_ACCOUNTS[@]}"; do
    if gcloud iam service-accounts describe "$build_sa" \
        --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
        echo "Granting roles to Cloud Build service account: $build_sa"
        for role in "${BUILD_ROLES[@]}"; do
            grant_project_role "serviceAccount:$build_sa" "$role"
        done
    else
        echo "Skipping missing Cloud Build service account: $build_sa"
    fi
done

echo ""
echo "=========================================="
echo "Step 8: Create Cloud Storage Bucket"
echo "=========================================="
echo ""

if [ -n "${GOOGLE_CLOUD_STORAGE_BUCKET:-}" ]; then
    BUCKET_NAME="${GOOGLE_CLOUD_STORAGE_BUCKET#gs://}"
    echo "Using bucket from .env: gs://$BUCKET_NAME"
else
    BUCKET_NAME="${GOOGLE_CLOUD_PROJECT}-content-studio"
fi

if gsutil ls -b "gs://$BUCKET_NAME" >/dev/null 2>&1; then
    echo "Storage bucket 'gs://$BUCKET_NAME' already exists"
else
    echo "Creating Cloud Storage bucket..."
    gcloud storage buckets create "gs://$BUCKET_NAME" \
        --location="$REGION" \
        --project="$GOOGLE_CLOUD_PROJECT"
    echo "Storage bucket created!"
fi

if ! grep -q "^GOOGLE_CLOUD_STORAGE_BUCKET=" "$ENV_FILE"; then
    echo "GOOGLE_CLOUD_STORAGE_BUCKET=gs://$BUCKET_NAME" >> "$ENV_FILE"
    echo "Updated .env with GOOGLE_CLOUD_STORAGE_BUCKET"
fi

echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Project: $GOOGLE_CLOUD_PROJECT"
echo "  Region: $REGION"
echo "  Artifact Registry: ${REGION}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${REPOSITORY_NAME}"
echo "  Cloud Run Service Account: $SERVICE_ACCOUNT_EMAIL"
echo "  Storage Bucket: gs://$BUCKET_NAME"
echo ""
echo "Next:"
echo "  1. Deploy the Agent Engine: uv run python deployment/deploy.py --action deploy"
echo "  2. Deploy the Cloud Run app: AUTO_APPROVE=true bash deployment/deploy-combined.sh"
echo "  3. Or run the complete flow: bash deployment/deploy-gcp.sh"
echo ""
