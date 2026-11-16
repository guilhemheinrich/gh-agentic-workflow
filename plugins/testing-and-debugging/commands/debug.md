# Debug Command Guide

This document describes the standard commands for debugging tasks.

## 1. Static Analysis (Health Check)

Before any dynamic analysis, verify code conformance:

- Run `make lint` if a Makefile is present.
- Identify typing errors or static analyzer warnings related to the bug.

## 2. Communication Layer Investigation

For bugs involving service exchanges:

- List containers: `docker ps --filter "label=com.docker.compose.project=<project_name>"`
- Check health: `docker inspect --format='{{json .State.Health}}' <container_id>`
- Trace HTTP/gRPC requests between containers
- Key commands:
  - `docker logs <container_name> --since 5m`
  - `docker exec <container_name> curl -v http://target-service:port`

## 3. Evidence Chain

Root Cause conclusions must be supported by tangible evidence:

- **Code bugs**: Provide complete **Stack Trace** with file and line number
- **Communication bugs**: Provide **Communication Log** excerpt (Request/Response Payload)

## 4. Logging Standard

When adding logs to isolate a bug:

- **Timestamping**: Prefix all logs with ISO 8601 timestamp for temporal correlation
- **Location**: Specify exact line and file for log insertion
- **Format**: `[YYYY-MM-DDTHH:mm:ss.sssZ] [DEBUG] [Context] Message...`

## 5. Report Requirements (bug-report.md)

Final report must include:

- **Investigation Matrix**: Expected vs observed behavior comparison
- **Docker Context**: List of images and networks involved
- **Reproduction Steps**: Deterministic instructions to reproduce the error
- **Root Cause**: Proven technical explanation
