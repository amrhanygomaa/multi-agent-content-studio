#!/bin/bash

# End-to-end GCP deployment:
# 1. Prepare Google Cloud resources and IAM.
# 2. Deploy the ADK orchestrator to Vertex AI Agent Engine when needed.
# 3. Deploy the bundled React + FastAPI app to Cloud Run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

echo "🚀 Content Creation Studio: full GCP deployment"
echo "================================================"
echo ""

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE"
    echo "Copy .env.example to .env and fill in your Google Cloud project settings."
    exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
    echo "❌ Error: gcloud was not found. Install the Google Cloud CLI first."
    exit 1
fi

cd "$PROJECT_ROOT"

export AUTO_APPROVE="${AUTO_APPROVE:-true}"

echo "Step 1/3: Preparing Google Cloud resources"
echo "------------------------------------------"
bash "$SCRIPT_DIR/setup_gcp.sh"

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

echo ""
echo "Step 2/3: Preparing Vertex AI Agent Engine"
echo "------------------------------------------"
if [ -n "${AGENT_ENGINE_RESOURCE_NAME:-}" ]; then
    echo "Agent Engine resource is already configured; skipping agent deployment."
else
    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        echo "❌ Application Default Credentials are not configured."
        echo "Run this once, then re-run the deploy script:"
        echo "  gcloud auth application-default login"
        exit 1
    fi

    if command -v uv >/dev/null 2>&1; then
        uv run python deployment/deploy.py --action deploy
    else
        python deployment/deploy.py --action deploy
    fi

    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

if [ -z "${AGENT_ENGINE_RESOURCE_NAME:-}" ]; then
    echo "❌ Agent Engine deployment did not populate AGENT_ENGINE_RESOURCE_NAME."
    exit 1
fi

echo ""
echo "Step 3/3: Deploying frontend + backend to Cloud Run"
echo "---------------------------------------------------"
bash "$SCRIPT_DIR/deploy-combined.sh"

echo ""
echo "✅ Full GCP deployment finished."
