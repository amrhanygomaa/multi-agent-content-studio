#!/bin/bash

# Deploy combined frontend + backend to Google Cloud Run.
# Builds in Cloud Build and runs the app as a single Cloud Run service.

set -euo pipefail

echo "🚀 Deploying Content Creation Studio (Combined Frontend + Backend) to Cloud Run"
echo "=============================================================================="

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

    read -p "Deploy to Cloud Run? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Deployment cancelled"
        exit 1
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "❌ Error: required command '$1' was not found"
        exit 1
    fi
}

load_env
require_command gcloud

if [ -z "${GOOGLE_CLOUD_PROJECT:-}" ]; then
    echo "❌ Error: GOOGLE_CLOUD_PROJECT is not set"
    echo "Please set it in your .env file or export it:"
    echo "  export GOOGLE_CLOUD_PROJECT=your-project-id"
    exit 1
fi

if [ -z "${AGENT_ENGINE_RESOURCE_NAME:-}" ]; then
    echo "⚠️  Warning: AGENT_ENGINE_RESOURCE_NAME is not set"
    echo "The service will deploy, but API calls will fail until the Agent Engine resource is configured."
    echo "Deploy your agent first using: python deployment/deploy.py --action deploy"
fi

REGION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-content-studio}"
REPOSITORY_NAME="${ARTIFACT_REPOSITORY_NAME:-content-studio}"
USE_ARTIFACT_REGISTRY="${USE_ARTIFACT_REGISTRY:-true}"

if [ "$USE_ARTIFACT_REGISTRY" = "true" ]; then
    IMAGE_NAME="${REGION}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${REPOSITORY_NAME}/${SERVICE_NAME}"
    REGISTRY_TYPE="Artifact Registry"
else
    IMAGE_NAME="gcr.io/${GOOGLE_CLOUD_PROJECT}/${SERVICE_NAME}"
    REGISTRY_TYPE="Container Registry (GCR)"
fi

echo ""
echo "📝 Configuration:"
echo "  Project: $GOOGLE_CLOUD_PROJECT"
echo "  Region: $REGION"
echo "  Service Name: $SERVICE_NAME"
echo "  Registry: $REGISTRY_TYPE"
echo "  Image: $IMAGE_NAME"
echo "  Agent Resource: $([ -n "${AGENT_ENGINE_RESOURCE_NAME:-}" ] && echo "Configured" || echo "Not configured")"
echo ""

confirm

cd "$PROJECT_ROOT"

echo ""
echo "🔧 Step 1/4: Preparing Google Cloud project..."
echo "----------------------------------------------"
gcloud config set project "$GOOGLE_CLOUD_PROJECT" >/dev/null

if [ "$USE_ARTIFACT_REGISTRY" = "true" ]; then
    if ! gcloud artifacts repositories describe "$REPOSITORY_NAME" \
        --location="$REGION" \
        --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
        echo "Creating Artifact Registry repository '$REPOSITORY_NAME'..."
        gcloud artifacts repositories create "$REPOSITORY_NAME" \
            --repository-format=docker \
            --location="$REGION" \
            --description="Docker repository for Content Creation Studio" \
            --project="$GOOGLE_CLOUD_PROJECT"
    fi
fi

echo ""
echo "🔨 Step 2/4: Building and pushing image via Cloud Build..."
echo "----------------------------------------------------------"
echo "  (Runs in GCP — no local Docker required)"
gcloud builds submit \
    --tag "$IMAGE_NAME" \
    --machine-type=e2-highcpu-8 \
    --project="$GOOGLE_CLOUD_PROJECT" \
    .
echo "✅ Image built and pushed successfully"

echo ""
echo "🚀 Step 3/4: Deploying to Cloud Run..."
echo "--------------------------------------"

SERVICE_ACCOUNT="${SERVICE_ACCOUNT_EMAIL:-content-studio-sa@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com}"
echo "  Service account: $SERVICE_ACCOUNT"

ENV_VARS=(
    "GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT"
    "GOOGLE_CLOUD_LOCATION=$REGION"
    "GOOGLE_GENAI_USE_VERTEXAI=${GOOGLE_GENAI_USE_VERTEXAI:-1}"
)

if [ -n "${AGENT_ENGINE_RESOURCE_NAME:-}" ]; then
    ENV_VARS+=(
        "AGENT_RESOURCE_NAME=$AGENT_ENGINE_RESOURCE_NAME"
        "AGENT_ENGINE_RESOURCE_NAME=$AGENT_ENGINE_RESOURCE_NAME"
    )
fi

if [ -n "${GEMINI_MODEL:-}" ]; then
    ENV_VARS+=("GEMINI_MODEL=$GEMINI_MODEL")
fi

if [ -n "${MAX_IMPROVEMENT_ITERATIONS:-}" ]; then
    ENV_VARS+=("MAX_IMPROVEMENT_ITERATIONS=$MAX_IMPROVEMENT_ITERATIONS")
fi

if [ -n "${GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY:-}" ]; then
    ENV_VARS+=("GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=$GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY")
fi

if [ -n "${OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED:-}" ]; then
    ENV_VARS+=("OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=$OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED")
fi

if [ -n "${OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT:-}" ]; then
    ENV_VARS+=("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=$OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT")
fi

if [ -n "${ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS:-}" ]; then
    ENV_VARS+=("ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=$ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS")
fi

ENV_VARS_CSV="$(IFS=,; echo "${ENV_VARS[*]}")"

gcloud run deploy "$SERVICE_NAME" \
    --image "$IMAGE_NAME" \
    --platform managed \
    --region "$REGION" \
    --project "$GOOGLE_CLOUD_PROJECT" \
    --allow-unauthenticated \
    --port 8080 \
    --memory 2Gi \
    --cpu 2 \
    --timeout 3600 \
    --max-instances 10 \
    --min-instances 0 \
    --service-account "$SERVICE_ACCOUNT" \
    --set-env-vars "$ENV_VARS_CSV"

echo ""
echo "✅ Step 4/4: Retrieving and checking service URL..."
echo "--------------------------------------------------"
SERVICE_URL="$(gcloud run services describe "$SERVICE_NAME" \
    --region "$REGION" \
    --project "$GOOGLE_CLOUD_PROJECT" \
    --format 'value(status.url)')"

if command -v curl >/dev/null 2>&1; then
    if curl -fsS "$SERVICE_URL/health" >/dev/null; then
        echo "✅ Health check passed"
    else
        echo "⚠️  Health check did not pass yet. Check Cloud Run logs if it persists."
    fi
fi

echo ""
echo "=============================================================================="
echo "✅ Deployment Complete!"
echo "=============================================================================="
echo ""
echo "🌐 Service URL: $SERVICE_URL"
echo ""
echo "📋 Next steps:"
echo "  1. Open the URL above in your browser to use the Content Studio"
echo "  2. The frontend and backend are served from a single Cloud Run service"
echo "  3. API endpoints are available at: $SERVICE_URL/api/*"
echo "  4. Health check: $SERVICE_URL/health"
echo ""
echo "📊 To view logs:"
echo "  gcloud run services logs read $SERVICE_NAME --region $REGION --project $GOOGLE_CLOUD_PROJECT"
echo ""
