#!/bin/bash

# GCP Cleanup Script for Content Creation Studio
# ==============================================
# This script removes all GCP resources created by the deployment scripts
# Use with caution - this will delete resources and may result in data loss!

set -e

echo "=============================================="
echo "  GCP Cleanup for Content Creation Studio"
echo "=============================================="
echo ""

# Load environment variables from project root .env (same logic as setup_gcp.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

if [ -f "$ENV_FILE" ]; then
    echo "📋 Loading environment variables from $ENV_FILE..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file not found at $ENV_FILE"
    exit 1
fi

# Check required environment variables
if [ -z "$GOOGLE_CLOUD_PROJECT" ]; then
    echo "❌ Error: GOOGLE_CLOUD_PROJECT not set"
    echo "Set it in .env file or export GOOGLE_CLOUD_PROJECT='your-project-id'"
    exit 1
fi

# Set defaults
REGION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-content-studio}"
SERVICE_ACCOUNT_NAME="content-studio-sa"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com"

# Determine bucket name
if [ -n "$GOOGLE_CLOUD_STORAGE_BUCKET" ]; then
    BUCKET_NAME="${GOOGLE_CLOUD_STORAGE_BUCKET#gs://}"
else
    BUCKET_NAME="${GOOGLE_CLOUD_PROJECT}-content-studio"
fi

echo "📝 Configuration:"
echo "  Project: $GOOGLE_CLOUD_PROJECT"
echo "  Region: $REGION"
echo "  Service Name: $SERVICE_NAME"
echo "  Storage Bucket: gs://$BUCKET_NAME"
echo "  Service Account: $SERVICE_ACCOUNT_EMAIL"
if [ -n "$AGENT_ENGINE_RESOURCE_NAME" ]; then
    echo "  Agent Engine: $AGENT_ENGINE_RESOURCE_NAME"
fi
echo ""

# Warning prompt
echo "⚠️  WARNING: This will DELETE the following resources:"
echo ""
echo "  1. Cloud Run service: $SERVICE_NAME"
echo "  2. Agent Engine: ${AGENT_ENGINE_RESOURCE_NAME:-Not configured}"
echo "  3. Docker images in Artifact Registry"
echo "  4. Service Account: $SERVICE_ACCOUNT_EMAIL (optional)"
echo "  5. Cloud Storage Bucket: gs://$BUCKET_NAME (optional)"
echo ""
echo "This action CANNOT be undone!"
echo ""
read -p "Are you sure you want to proceed? (yes/no): " -r
echo ""

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "❌ Cleanup cancelled"
    exit 0
fi

# Set project
echo ""
echo "=============================================="
echo "Step 1: Setting Project Context"
echo "=============================================="
echo ""
gcloud config set project $GOOGLE_CLOUD_PROJECT
echo "✅ Project set to: $GOOGLE_CLOUD_PROJECT"

# Delete Cloud Run Service
echo ""
echo "=============================================="
echo "Step 2: Deleting Cloud Run Service"
echo "=============================================="
echo ""

if gcloud run services describe $SERVICE_NAME --region=$REGION --project=$GOOGLE_CLOUD_PROJECT &>/dev/null; then
    echo "🗑️  Deleting Cloud Run service: $SERVICE_NAME..."
    gcloud run services delete $SERVICE_NAME \
        --region=$REGION \
        --project=$GOOGLE_CLOUD_PROJECT \
        --quiet
    echo "✅ Cloud Run service deleted"
else
    echo "ℹ️  Cloud Run service '$SERVICE_NAME' not found (already deleted or never created)"
fi

# Delete Agent Engine
echo ""
echo "=============================================="
echo "Step 3: Deleting Agent Engine"
echo "=============================================="
echo ""

if [ -n "$AGENT_ENGINE_RESOURCE_NAME" ]; then
    echo "🗑️  Deleting Agent Engine: $AGENT_ENGINE_RESOURCE_NAME..."

    # Use inline Python — avoids importing the agent package (which requires full venv)
    python3 -c "
import sys
try:
    import vertexai
    from vertexai import agent_engines
    vertexai.init(project='$GOOGLE_CLOUD_PROJECT', location='$REGION')
    engine = agent_engines.get('$AGENT_ENGINE_RESOURCE_NAME')
    engine.delete(force=True)
    print('Agent Engine deleted successfully')
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" || {
        echo "⚠️  Python deletion failed, trying gcloud command..."
        ENGINE_ID=$(echo "$AGENT_ENGINE_RESOURCE_NAME" | awk -F'/' '{print $NF}')
        gcloud ai reasoning-engines delete "$ENGINE_ID" \
            --location="$REGION" \
            --project="$GOOGLE_CLOUD_PROJECT" \
            --quiet || echo "⚠️  Failed to delete Agent Engine (may already be deleted)"
    }
    echo "✅ Agent Engine cleanup attempted"
else
    echo "ℹ️  AGENT_ENGINE_RESOURCE_NAME not set (skipping Agent Engine cleanup)"
fi

# Delete Docker Images from Artifact Registry
echo ""
echo "=============================================="
echo "Step 4: Deleting Docker Images"
echo "=============================================="
echo ""

REPO_NAME="content-studio"

if gcloud artifacts repositories describe $REPO_NAME \
    --location=$REGION \
    --project=$GOOGLE_CLOUD_PROJECT &>/dev/null; then

    echo "🗑️  Deleting images in repository: $REPO_NAME..."

    # List and delete all images in the repository
    IMAGES=$(gcloud artifacts docker images list \
        ${REGION}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${REPO_NAME} \
        --format="value(package)" 2>/dev/null || true)

    if [ -n "$IMAGES" ]; then
        echo "$IMAGES" | while read -r image; do
            if [ -n "$image" ]; then
                echo "  Deleting image: $image"
                gcloud artifacts docker images delete "$image" --delete-tags --quiet || true
            fi
        done
        echo "✅ Docker images deleted"
    else
        echo "ℹ️  No Docker images found in repository"
    fi

    # Ask if user wants to delete the entire repository
    echo ""
    read -p "Delete Artifact Registry repository '$REPO_NAME'? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        gcloud artifacts repositories delete $REPO_NAME \
            --location=$REGION \
            --project=$GOOGLE_CLOUD_PROJECT \
            --quiet
        echo "✅ Artifact Registry repository deleted"
    else
        echo "ℹ️  Keeping Artifact Registry repository"
    fi
else
    echo "ℹ️  Artifact Registry repository '$REPO_NAME' not found"
fi

# Delete Service Account (optional)
echo ""
echo "=============================================="
echo "Step 5: Deleting Service Account (Optional)"
echo "=============================================="
echo ""

if gcloud iam service-accounts describe $SERVICE_ACCOUNT_EMAIL \
    --project=$GOOGLE_CLOUD_PROJECT &>/dev/null; then

    read -p "Delete service account '$SERVICE_ACCOUNT_EMAIL'? (y/n): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🗑️  Removing IAM role bindings..."

        ROLES=(
            "roles/aiplatform.user"
            "roles/run.invoker"
            "roles/storage.objectViewer"
            "roles/logging.logWriter"
            "roles/artifactregistry.writer"
        )

        for role in "${ROLES[@]}"; do
            echo "  Removing role: $role"
            gcloud projects remove-iam-policy-binding $GOOGLE_CLOUD_PROJECT \
                --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
                --role="$role" \
                --quiet &>/dev/null || true
        done

        echo "🗑️  Deleting service account..."
        gcloud iam service-accounts delete $SERVICE_ACCOUNT_EMAIL \
            --project=$GOOGLE_CLOUD_PROJECT \
            --quiet

        echo "✅ Service account deleted"
    else
        echo "ℹ️  Keeping service account"
    fi
else
    echo "ℹ️  Service account not found (already deleted or never created)"
fi

# Delete Cloud Storage Bucket (optional)
echo ""
echo "=============================================="
echo "Step 6: Deleting Cloud Storage Bucket (Optional)"
echo "=============================================="
echo ""

if gsutil ls -b gs://$BUCKET_NAME &>/dev/null; then
    echo "⚠️  WARNING: This will delete ALL files in the bucket!"
    read -p "Delete storage bucket 'gs://$BUCKET_NAME'? (y/n): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🗑️  Deleting bucket and all contents..."
        gsutil -m rm -r gs://$BUCKET_NAME || true
        echo "✅ Storage bucket deleted"
    else
        echo "ℹ️  Keeping storage bucket"
    fi
else
    echo "ℹ️  Storage bucket 'gs://$BUCKET_NAME' not found"
fi

# Delete Cloud Build Bucket (optional)
echo ""
echo "=============================================="
echo "Step 7: Deleting Cloud Build Bucket (Optional)"
echo "=============================================="
echo ""

CLOUDBUILD_BUCKET="${GOOGLE_CLOUD_PROJECT}_cloudbuild"

if gsutil ls -b "gs://$CLOUDBUILD_BUCKET" &>/dev/null; then
    echo "⚠️  WARNING: This will delete ALL Cloud Build logs and source archives!"
    read -p "Delete Cloud Build bucket 'gs://$CLOUDBUILD_BUCKET'? (y/n): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🗑️  Deleting Cloud Build bucket and all contents..."
        gsutil -m rm -r "gs://$CLOUDBUILD_BUCKET" || true
        gsutil rb "gs://$CLOUDBUILD_BUCKET" || true
        echo "✅ Cloud Build bucket deleted"
    else
        echo "ℹ️  Keeping Cloud Build bucket"
    fi
else
    echo "ℹ️  Cloud Build bucket 'gs://$CLOUDBUILD_BUCKET' not found"
fi

# Summary
echo ""
echo "=============================================="
echo "  Cleanup Complete!"
echo "=============================================="
echo ""
echo "📊 Summary:"
echo "  ✅ Cloud Run service cleanup: Done"
echo "  ✅ Agent Engine cleanup: Done"
echo "  ✅ Docker images cleanup: Done"
echo "  ✅ Service account cleanup: Done"
echo "  ✅ Storage bucket cleanup: Done"
echo "  ✅ Cloud Build bucket cleanup: Done"
echo ""
echo "💡 Note: The following may still exist:"
echo "  - Enabled APIs (these don't cost money when idle)"
echo "  - Cloud Logging entries"
echo ""
echo "To also disable APIs (optional):"
echo "  gcloud services disable aiplatform.googleapis.com run.googleapis.com \\"
echo "    cloudbuild.googleapis.com artifactregistry.googleapis.com \\"
echo "    --project=$GOOGLE_CLOUD_PROJECT"
echo ""
echo "All cleanup operations completed!"
echo ""
