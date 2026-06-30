# Production image for the self-hosted Mem0 REST server.
# Build context MUST be the repository root so the local (forked) `mem0`
# package is bundled into the image instead of the published PyPI release.
#
#   docker build -f server/prod.Dockerfile -t mem0-server .
#
# Runtime entrypoint applies Alembic migrations, then starts uvicorn WITHOUT
# --reload (reload is a development-only feature and leaks file watchers).
FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# curl is used by the container healthcheck.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# 1. Server dependencies (FastAPI, auth, drivers, bundled providers).
COPY server/requirements.txt ./requirements.txt
RUN pip install -r requirements.txt

# 2. Install the local forked mem0 package. This is installed AFTER the
#    requirements so it overrides the PyPI `mem0ai` pulled in transitively,
#    ensuring any fork changes under mem0/ are the version that runs.
COPY pyproject.toml README.md ./pkg/
COPY mem0 ./pkg/mem0
RUN pip install "./pkg"

# 3. Server application code.
COPY server/ ./

EXPOSE 8000

# Apply DB migrations on boot, then serve. Single source of truth for the
# port is here; the compose file maps the host port onto 8000.
CMD ["sh", "-c", "alembic upgrade head && uvicorn main:app --host 0.0.0.0 --port 8000"]
