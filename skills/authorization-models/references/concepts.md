# Authorization Concepts

Sources:

- Permit.io, "Authorization Policy Showdown: RBAC vs. ABAC vs. ReBAC": https://www.permit.io/blog/rbac-vs-abac-vs-rebac
- OPA philosophy: https://www.openpolicyagent.org/docs/philosophy
- Apache Casbin supported models: https://casbin.apache.org/docs/supported-models/

## Core Vocabulary

Authorization answers: can this subject perform this action on this resource under this context?

Use this normalized request shape in specs:

```json
{
  "subject": {"id": "user_123", "type": "user", "tenant": "acme"},
  "action": "document:update",
  "resource": {"id": "doc_456", "type": "document", "tenant": "acme"},
  "context": {"ip": "203.0.113.10", "time": "2026-06-25T10:00:00Z"}
}
```

Define each datum as:

- `input`: supplied by the request or authenticated identity.
- `data`: replicated or queried authorization facts such as roles, attributes, relationships, plans, or policy tables.
- `policy`: rules that evaluate input and data.
- `decision`: usually `allow`, `deny`, and optional explanation/audit fields.

Default to deny. Missing or stale data should deny unless the product explicitly accepts fail-open behavior for that endpoint.

## Model Selection

| Model | Best fit | Main risk | Example rule |
| --- | --- | --- | --- |
| ACL | Small explicit sharing lists | Hard to manage at scale | `alice can read document:123` |
| RBAC | Job functions, coarse admin/editor/viewer roles | Role explosion | `tenant admin can invite users` |
| RBAC with domains | Multi-tenant apps | Tenant leakage if domain is not always in the check | `alice is admin in tenant A, viewer in tenant B` |
| ABAC | Decisions based on attributes | Attribute sourcing and policy complexity | `EU employees can edit GDPR documents` |
| ReBAC | Hierarchies, ownership, teams, nested folders | Recursive graph complexity and auditability | `folder editors can edit files in that folder` |
| PBAC / policy-as-code | Cross-service or regulated policy lifecycle | Requires policy tooling and tests | `deny exports unless risk score and purpose allow it` |

Most real systems combine models. Use RBAC for coarse grants, ABAC for contextual constraints, and ReBAC for ownership or hierarchy inheritance.

## RBAC

RBAC maps subjects to roles and roles to permissions.

Minimal data:

```json
{
  "user_roles": {
    "alice": ["editor"],
    "bob": ["admin"]
  },
  "role_permissions": {
    "viewer": ["document:read"],
    "editor": ["document:read", "document:update"],
    "admin": ["document:*"]
  }
}
```

Good RBAC spec questions:

- Are roles global, tenant-scoped, project-scoped, or resource-scoped?
- Can roles inherit from other roles?
- Who can assign each role?
- Are dangerous roles mutually exclusive?
- What audit trail exists for role assignment changes?

Use RBAC when roles reflect stable product concepts. Do not create `invoice-editor-eu-active-premium-after-hours` roles; that is ABAC pressure.

## ABAC

ABAC evaluates attributes on the subject, resource, action, and environment.

Examples:

- subject attributes: department, clearance, employment status, verified email
- resource attributes: tenant, owner, classification, lifecycle state
- action attributes: read-only vs destructive, export vs view
- environment attributes: time, IP range, device posture, billing status

ABAC request and data example:

```json
{
  "input": {
    "subject": {"id": "alice", "department": "legal", "region": "EU"},
    "resource": {"id": "doc1", "classification": "gdpr", "owner_department": "legal"},
    "action": "document:update"
  }
}
```

Good ABAC spec questions:

- Which service owns each attribute?
- Is the attribute trusted at decision time?
- Is the value fresh enough for the risk?
- Is there a fallback when the attribute is absent?
- Can product/admin users understand why a decision was denied?

ABAC is powerful, but every new attribute is a data dependency. Keep high-risk attributes server-side and avoid trusting client-supplied context unless validated.

## ReBAC

ReBAC evaluates relationships between subjects and resources. It fits collaboration products, organizations, teams, folders, projects, groups, and delegated ownership.

Relationship tuples are easier to reason about when they follow:

```text
subject relation object
user:alice member_of team:legal
team:legal editor project:contract-review
project:contract-review parent folder:contracts
document:doc1 parent folder:contracts
```

Typical derived rule:

```text
user can update document if
  user is editor of the document, or
  user is member of a team that is editor of a project/folder containing the document
```

Good ReBAC spec questions:

- Which relationships are direct, and which are derived?
- Are relationships tenant-scoped?
- How deep can inheritance recurse?
- Are cycles possible, and how are they handled?
- Can the system answer reverse queries such as "who can access this document"?

ReBAC reduces per-resource policy duplication for hierarchy-based access, but it needs careful graph boundaries, cycle handling, and audit tooling.

## PBAC And Policy-As-Code

PBAC is useful when policy is a first-class artifact: reviewed, versioned, tested, distributed, and evaluated consistently. OPA is a common fit for this style.

Use policy-as-code when:

- policies must apply across many services or gateways
- policy changes should not require application redeploys
- decisions need strong tests and review history
- the same language should cover app authorization, infrastructure, CI/CD, or admission control

## Spec Checklist

Every authorization design should state:

- protected resources and action taxonomy
- model choice and rejected alternatives
- request shape and enforcement point
- data sources for roles, attributes, and relationships
- tenant/domain boundary and isolation invariant
- policy update flow and rollback strategy
- audit log fields: subject, action, resource, decision, policy version, reason
- test matrix for positive, negative, cross-tenant, missing data, stale data, and privilege escalation cases
