# Supervisor-free image for the pr-watch and linear-watch daemons (Windows hosts
# have no launchd). Build context = repository root:
#   docker build -f scripts/watchers-docker/Dockerfile -t watchers .
FROM python:3.12-slim

# Linear CLI release used by `lw` (https://github.com/schpet/linear-cli).
# Override with --build-arg LINEAR_CLI_VERSION=vX.Y.Z.
ARG LINEAR_CLI_VERSION=v3.1.0
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash curl jq git tini ca-certificates xz-utils \
 && rm -rf /var/lib/apt/lists/*

# The linear binary: the release tarball of the matching Linux architecture,
# checked against the .sha256 file published next to it.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) triple=x86_64-unknown-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/schpet/linear-cli/releases/download/${LINEAR_CLI_VERSION}"; \
    cd /tmp; \
    curl -fsSL -O "${base}/linear-${triple}.tar.xz"; \
    curl -fsSL -O "${base}/linear-${triple}.tar.xz.sha256"; \
    sha256sum -c "linear-${triple}.tar.xz.sha256"; \
    mkdir linear-dist; \
    tar -xJf "linear-${triple}.tar.xz" -C linear-dist; \
    install -m 0755 "$(find linear-dist -type f -name linear | head -n 1)" /usr/local/bin/linear; \
    rm -rf /tmp/linear*; \
    linear --version

# Copied, not mounted: the scripts then do not live in a git checkout, so the
# "refusing: runs from a git checkout" guards stay armed and untouched.
COPY skills/pr-watch /opt/watchers/pr-watch
COPY skills/linear-tracker /opt/watchers/linear-tracker

RUN useradd --create-home --uid 10001 --shell /bin/bash watcher \
 && mkdir -p /var/lib/watchers/prw /var/lib/watchers/lw \
 && chown -R watcher:watcher /var/lib/watchers

ENV PRW_STATE_DIR=/var/lib/watchers/prw \
    LW_STATE_DIR=/var/lib/watchers/lw \
    LW_LINEAR_BIN=/usr/local/bin/linear \
    PYTHONUNBUFFERED=1

USER watcher
WORKDIR /home/watcher
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bash", "/opt/watchers/pr-watch/scripts/prw", "daemon", "run"]
