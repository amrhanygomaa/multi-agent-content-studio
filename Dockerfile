# Multi-stage build for React frontend + FastAPI backend
# Combines both into a single Cloud Run service

# Stage 1: Build React frontend
FROM node:20-alpine AS frontend-build

WORKDIR /frontend

COPY frontend/package*.json ./
RUN npm ci

COPY frontend/ ./

# Remove .env files to prevent localhost URLs in production build
RUN rm -f .env .env.local .env.development .env.production

RUN npm run build

# Stage 2: Python backend with uv
FROM python:3.12-slim

RUN pip install --no-cache-dir uv==0.8.13

WORKDIR /code

# Copy project metadata first for better layer caching
COPY pyproject.toml uv.lock* ./

# Copy first-party packages
COPY agents ./agents
COPY common ./common
COPY backend ./backend

# Install dependencies into the system Python (no project venv)
RUN uv sync --frozen --no-dev

# Copy built frontend from previous stage — must live next to api_server.py
# because api_server.py uses Path(__file__).parent / "static" to locate it
COPY --from=frontend-build /frontend/dist ./backend/static

ARG COMMIT_SHA=""
ENV COMMIT_SHA=${COMMIT_SHA}

ENV PORT=8080
EXPOSE 8080

# Cloud Run sets PORT=8080
CMD exec uv run uvicorn backend.api_server:app --host 0.0.0.0 --port ${PORT}
