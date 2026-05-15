# Multi-Agent Content Studio

End-to-end Google Cloud deployment for a React + FastAPI content studio powered by
Google ADK agents on Vertex AI Agent Engine.

## Google Cloud Architecture

- **Vertex AI Agent Engine** runs the multi-agent ADK orchestrator.
- **Cloud Run** serves the bundled FastAPI backend and React frontend from one container.
- **Artifact Registry** stores the Cloud Run container image.
- **Cloud Build** builds the production image in GCP.
- **Cloud Storage** is used as the Agent Engine staging bucket.
- **Cloud Logging / Trace / Telemetry** receive runtime observability data.

## Deploy To GCP

1. Copy the environment template:

   ```bash
   cp .env.example .env
   ```

2. Fill in at least:

   ```bash
   GOOGLE_CLOUD_PROJECT=your-project-id
   GOOGLE_CLOUD_LOCATION=us-central1
   GOOGLE_CLOUD_STORAGE_BUCKET=gs://your-project-id-content-studio
   ```

3. Authenticate locally:

   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

4. Run the full deployment from Windows PowerShell:

   ```powershell
   .\deployment\deploy-gcp.ps1 -AutoApprove
   ```

   Or from Cloud Shell / Linux / macOS:

   ```bash
   bash deployment/deploy-gcp.sh
   ```

The full deploy script prepares GCP resources, deploys the ADK agent to Vertex AI
Agent Engine if `AGENT_ENGINE_RESOURCE_NAME` is empty, then deploys the combined
frontend/backend service to Cloud Run.

## Update An Existing Deployment

After the first deployment, when `AGENT_ENGINE_RESOURCE_NAME` already exists in
`.env`, update only the Cloud Run app:

```bash
AUTO_APPROVE=true bash deployment/deploy-combined.sh
```

From Windows PowerShell:

```powershell
.\deployment\deploy-combined.ps1 -AutoApprove
```

## Local Checks

```bash
python -m compileall -q agents backend common
cd frontend && npm ci && npm run build
```

## Secret Handling

`.env` is intentionally ignored by both Git and Docker build context. Keep real
project IDs, resource names, and credentials in `.env`; commit only `.env.example`.
