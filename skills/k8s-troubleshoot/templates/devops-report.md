# DevOps Report — [PROBLEM TITLE]

**Date**: [YYYY-MM-DD HH:MM]
**Namespace**: [namespace]
**Affected resource**: [type/name, e.g., deployment/modelo-meet-api]
**Priority**: [RED Critical / ORANGE High / YELLOW Medium]
**Cluster**: [cluster name]

## 1. Observed Problem

[Factual, concise description of the observed problem. No interpretation here.]

## 2. Evidence (Logs & Events)

### Kubernetes Events

```
[Filtered output from kubectl get events --sort-by='.lastTimestamp']
```

### Pod Logs

```
[Relevant excerpts from kubectl logs]
```

### Resource Description

```
[Relevant excerpts from kubectl describe]
```

## 3. Probable Cause

[Root cause analysis based on the evidence above]

## 4. Requested Action

[Precise description of what the DevOps team must do]

**Suggested command(s)** (if applicable):

```bash
# Example command the DevOps team should execute
```

## 5. Justification

[Why this action is necessary. Explicit link between the cause and the requested action.
The DevOps team must understand the "why" without needing additional context.]

## 6. Impact if Left Unresolved

[Consequences of inaction: service degradation, data loss, etc.]
