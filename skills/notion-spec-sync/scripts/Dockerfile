FROM python:3.12-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends git \
  && rm -rf /var/lib/apt/lists/*

COPY build_notion_spec_sync_plan.py /usr/local/bin/notion-spec-sync-plan
RUN chmod +x /usr/local/bin/notion-spec-sync-plan

WORKDIR /workspace
ENTRYPOINT ["notion-spec-sync-plan"]
