# OPA Implementation Guide

Sources:

- OPA philosophy: https://www.openpolicyagent.org/docs/philosophy
- OPA policy language / Rego: https://www.openpolicyagent.org/docs/policy-language
- OPA REST API: https://www.openpolicyagent.org/docs/rest-api
- OPA HTTP API authorization tutorial: https://www.openpolicyagent.org/docs/http-api-authorization
- OPA bundles: https://www.openpolicyagent.org/docs/management-bundles
- OPA external data: https://www.openpolicyagent.org/docs/external-data
- OPA deployment guide: https://www.openpolicyagent.org/docs/deploy

## Mental Model

OPA is a policy decision point. Applications, gateways, admission controllers, or CI jobs send structured input to OPA. OPA evaluates Rego policy against that input and against replicated data, then returns a decision.

OPA should not be the source of truth for application data. Treat it as a cache/replica of policy and authorization data, refreshed through bundles, discovery, data APIs, or side-loaded files depending on consistency needs.

Recommended decision contract:

```json
{
  "input": {
    "subject": {"id": "alice", "tenant": "acme", "roles": ["editor"]},
    "action": "document:update",
    "resource": {"id": "doc1", "tenant": "acme", "classification": "internal"},
    "context": {"method": "PATCH", "path": "/documents/doc1"}
  }
}
```

Recommended response contract:

```json
{
  "allow": true,
  "reason": "tenant editor can update internal documents",
  "policy_version": "2026-06-25.1"
}
```

## Rego Skeleton

Use a package path that matches the decision endpoint:

```rego
package app.authz

default allow := false

decision := {
  "allow": allow,
  "reason": reason,
}

default reason := "default deny"

allow if {
  same_tenant
  input.action == "document:read"
  has_permission("document:read")
}

allow if {
  same_tenant
  input.action == "document:update"
  has_permission("document:update")
  not input.resource.locked
}

reason := "allowed by role permission" if allow

same_tenant if {
  input.subject.tenant == input.resource.tenant
}

has_permission(permission) if {
  some role in input.subject.roles
  permission in data.role_permissions[role]
}
```

Query it through the Data API at:

```text
POST /v1/data/app/authz/decision
```

with body:

```json
{"input": {"subject": {"tenant": "acme", "roles": ["editor"]}, "action": "document:update", "resource": {"tenant": "acme", "locked": false}}}
```

## RBAC In OPA

Keep role assignments either in trusted input claims for low-risk cases, or in `data` replicated from the application database for stronger control.

Example data:

```json
{
  "role_permissions": {
    "viewer": ["document:read"],
    "editor": ["document:read", "document:update"],
    "admin": ["document:read", "document:update", "document:delete"]
  }
}
```

Rules:

```rego
has_permission(permission) if {
  role := input.subject.roles[_]
  permission in data.role_permissions[role]
}

has_permission(permission) if {
  role := input.subject.roles[_]
  "*" in data.role_permissions[role]
}
```

For tenant RBAC, always include domain/tenant in the role assignment:

```json
{
  "tenant_roles": {
    "acme": {"alice": ["admin"]},
    "globex": {"alice": ["viewer"]}
  }
}
```

```rego
subject_roles contains role if {
  role := data.tenant_roles[input.resource.tenant][input.subject.id][_]
}
```

## ABAC In OPA

Put server-trusted attributes in `input` or `data`, not in client-controlled request bodies.

```rego
allow if {
  input.action == "document:update"
  input.subject.department == input.resource.owner_department
  input.resource.classification != "restricted"
  input.context.network == "trusted"
}
```

Use ABAC for contextual constraints layered on top of RBAC:

```rego
allow if {
  has_permission(input.action)
  input.subject.tenant == input.resource.tenant
  not high_risk_export
}

high_risk_export if {
  input.action == "document:export"
  input.resource.classification in {"confidential", "restricted"}
  input.context.mfa_verified != true
}
```

## ReBAC In OPA

Represent relationships as tuples or indexed maps. Keep recursion bounded and test cycles.

Tuple data:

```json
{
  "relationships": [
    {"subject": "user:alice", "relation": "member", "object": "team:legal"},
    {"subject": "team:legal", "relation": "editor", "object": "folder:contracts"},
    {"subject": "document:doc1", "relation": "parent", "object": "folder:contracts"}
  ]
}
```

Small relationship helper:

```rego
rel(subject, relation, object) if {
  some r in data.relationships
  r.subject == subject
  r.relation == relation
  r.object == object
}

team_member(user, team) if {
  rel(sprintf("user:%s", [user]), "member", sprintf("team:%s", [team]))
}

can_edit_document if {
  input.action == "document:update"
  rel(sprintf("document:%s", [input.resource.id]), "parent", folder)
  rel(team, "editor", folder)
  startswith(team, "team:")
  team_id := trim_prefix(team, "team:")
  team_member(input.subject.id, team_id)
}
```

For deep hierarchy traversal, prefer precomputed closure/indexes in `data` if policy latency matters. Store relationship updates in the application database, then replicate a read-optimized view into OPA.

## Bundles

Use bundles when OPA needs to update policy and data without redeploying the application.

Bundle layout:

```text
bundle/
  app/authz.rego
  data.json
  .manifest
```

Minimal OPA config:

```yaml
services:
  policy_service:
    url: https://policy.example.com

bundles:
  authz:
    service: policy_service
    resource: bundles/authz.tar.gz
    polling:
      min_delay_seconds: 10
      max_delay_seconds: 60
```

Implementation notes:

- Version every bundle and include the version in decisions or decision logs.
- Validate bundles in CI with `opa test` before publishing.
- Keep emergency rollback simple: republish the previous bundle version.
- Avoid putting very high-churn data in bundles if update latency is unacceptable.

## External Data Strategy

Choose the data path by freshness and size:

- JWT/input claims: cheap and fast, but only for trusted, signed, low-churn attributes.
- Bundle data: good for policy tables and moderate-change reference data.
- Data API push: good when an app or controller updates OPA replicas.
- Direct HTTP built-ins: use sparingly for exceptional data, because they introduce latency and availability coupling.
- Application-side enrichment: often best for request-specific data already owned by the service.

Never let OPA silently decide with half-populated data. Add tests for missing attributes and missing relationship indexes.

## Testing

Use table tests around decisions:

```rego
package app.authz_test

import data.app.authz

test_editor_can_update_unlocked_document if {
  authz.allow with input as {
    "subject": {"tenant": "acme", "roles": ["editor"]},
    "action": "document:update",
    "resource": {"tenant": "acme", "locked": false}
  } with data.role_permissions as {"editor": ["document:update"]}
}

test_cross_tenant_denied if {
  not authz.allow with input as {
    "subject": {"tenant": "acme", "roles": ["editor"]},
    "action": "document:update",
    "resource": {"tenant": "globex", "locked": false}
  } with data.role_permissions as {"editor": ["document:update"]}
}
```

Minimum test matrix:

- allowed happy path
- denied by default
- denied cross-tenant
- denied missing role/attribute/relationship
- denied stale or unknown resource state
- denied sensitive export without required context
- admin/superuser path, if one exists

## Implementation Checklist

- Define a stable package and decision endpoint.
- Keep request input small and explicit.
- Normalize action names; avoid route strings as the only permission names.
- Keep tenant/domain in every relevant input and data key.
- Add decision logs with subject, action, resource, decision, policy version, and reason.
- Run `opa fmt`, `opa check`, and `opa test` in CI.
- Decide bundle rollout and rollback before production.
- Document fail-closed vs fail-open behavior for OPA unavailability.
