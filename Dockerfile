# syntax=docker/dockerfile:1.7
# =============================================================================
# claude-code-telegram — multi-stage production image
# Base:   python:3.11-slim-bookworm (Debian 12, minimal attack surface)
# Poetry: 2.1.3 (pinned, isolated installer, venv copied into runtime)
# User:   botuser (UID/GID 1001), non-root
# Volumes: /app (code), /data (SQLite+sessions), /projects (workspaces), /config (yaml)
# =============================================================================

ARG PYTHON_VERSION=3.11
ARG POETRY_VERSION=2.1.3
ARG APP_UID=1001
ARG APP_GID=1001


# -----------------------------------------------------------------------------
# Stage 1: builder — resolve + install dependencies into a venv
# -----------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

ARG POETRY_VERSION

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    POETRY_VERSION=${POETRY_VERSION} \
    POETRY_HOME=/opt/poetry \
    POETRY_NO_INTERACTION=1 \
    POETRY_VIRTUALENVS_CREATE=true \
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    POETRY_CACHE_DIR=/tmp/poetry-cache \
    PATH="/opt/poetry/bin:${PATH}"

# Build deps: curl for installer, git for VCS-backed packages (if any appear later),
# build-essential is NOT included on purpose — wheels cover current deps.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        git \
 && rm -rf /var/lib/apt/lists/*

# Install Poetry via official installer into isolated location.
RUN curl -sSL https://install.python-poetry.org | python3 - --version ${POETRY_VERSION} \
 && poetry --version

WORKDIR /build

# Copy only dependency manifests first → maximal layer cache.
COPY pyproject.toml poetry.lock ./

# Install main deps only (no dev, no root project) into /build/.venv.
RUN --mount=type=cache,target=/tmp/poetry-cache \
    poetry install --only main --no-root --no-ansi


# -----------------------------------------------------------------------------
# Stage 2: runtime — slim final image with venv + application code
# -----------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG APP_UID
ARG APP_GID

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH="/app/.venv/bin:${PATH}" \
    VIRTUAL_ENV=/app/.venv \
    APP_HOME=/app \
    DATA_DIR=/data \
    PROJECTS_DIR=/projects \
    CONFIG_DIR=/config

# Runtime deps kept minimal:
#   - git: required for entrypoint `git clone/pull` of workspaces
#   - tini: proper PID 1 signal handling
#   - ca-certificates: HTTPS outbound (Telegram, Anthropic, GitHub)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        git \
        tini \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Non-root user + required mount dirs (pre-created so bind mounts inherit perms cleanly).
RUN groupadd --system --gid ${APP_GID} botuser \
 && useradd --system --uid ${APP_UID} --gid ${APP_GID} \
        --create-home --home-dir /home/botuser --shell /usr/sbin/nologin botuser \
 && mkdir -p /app /data /projects /config \
 && chown -R botuser:botuser /app /data /projects /config /home/botuser

WORKDIR /app

# Copy pre-built venv from builder stage.
COPY --from=builder --chown=botuser:botuser /build/.venv /app/.venv

# Copy low-churn startup scripts BEFORE source so code edits don't invalidate
# the scripts layer. chmod is done as root; USER directive below drops privs.
COPY --chown=botuser:botuser scripts/ ./scripts/
RUN chmod 0755 /app/scripts/*.sh

# Copy application source last — highest-churn layer.
COPY --chown=botuser:botuser pyproject.toml README.md ./
COPY --chown=botuser:botuser src/ ./src/

# Declare persistent volumes. Runtime host-side bind mounts override these.
VOLUME ["/data", "/projects", "/config"]

USER botuser:botuser

# Healthcheck: verify Python can import the main module and settings load.
# Lightweight — no network call — avoids false positives during Telegram outages.
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python -c "import src.main; print('ok')" || exit 1

# entrypoint.sh runs workspace sync, then execs `tini -- claude-telegram-bot`.
# tini still becomes PID 1 via exec — signal handling unaffected.
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["python", "-m", "src.main"]
