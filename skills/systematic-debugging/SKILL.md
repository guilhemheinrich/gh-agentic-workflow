---
title: "Skill: Systematic Debugging"
description: "Multi-layer investigation methodology: Static, Network, Code and Logs. See RESOURCES.md for complete Docker command reference."
tags:
  - common
version: "1.0.0"
---

# Skill: Systematic Debugging

This skill defines the technical rigor expected during any bug investigation.

## 1. Static Analysis (Health Check)

Before any dynamic analysis, verify code conformance:

- Run `make lint` if a Makefile is present.
- Identify typing errors or static analyzer warnings that correlate with the bug.

## 2. Communication Layer Analysis

If the bug involves exchanges between services or entities:

- **Docker Identification**:
  - List project containers: `docker ps --filter "label=com.docker.compose.project=<project_name>"`
  - Check health status: `docker inspect --format='{{json .State.Health}}' <container_id>`
- **Network Traces**: Trace HTTP/gRPC requests between containers.
- **Key Commands**:
  - `docker logs <container_name> --since 5m`
  - `docker exec <container_name> curl -v http://target-service:port` (connectivity test).

## 3. Evidence Chain (Proof Chain)

Any conclusion on "Root Cause" must be supported by tangible evidence:

- **Code Bugs**: Provide the complete **Stack Trace** identifying the file and line number.
- **Communication Bugs**: Provide the excerpt from the **Communication Log** (Request/Response Payload).

## 4. Logging & Instrumentation Standard

If logs must be added to isolate the bug:

- **Timestamping**: All added logs must be prefixed with an ISO 8601 timestamp to enable temporal correlation of streams.
- **Location**: Precisely indicate the line and file where the log statement should be inserted.
- **Suggested Format**: `[YYYY-MM-DDTHH:mm:ss.sssZ] [DEBUG] [Context] Message...`

## 5. Reporting Criteria (bug-report.md)

The final report must systematically include:

- **Investigation Matrix**: Comparison table of expected vs observed behavior.
- **Docker Context**: List of images and networks involved.
- **Reproduction Steps**: Deterministic instructions to reproduce the error.
- **Root Cause**: Proven technical explanation.

## Resource Reference

See `RESOURCES.md` for a comprehensive Docker debugging command reference.
