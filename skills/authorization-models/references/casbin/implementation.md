# Apache Casbin Implementation Guide

Sources:

- Apache Casbin overview: https://casbin.apache.org/docs/overview/
- Get started: https://casbin.apache.org/docs/get-started/
- Supported models: https://casbin.apache.org/docs/supported-models/
- Model syntax: https://casbin.apache.org/docs/syntax-for-models/
- RBAC: https://casbin.apache.org/docs/rbac/
- RBAC with domains: https://casbin.apache.org/docs/rbac-with-domains/
- ABAC: https://casbin.apache.org/docs/abac/
- ReBAC: https://casbin.apache.org/docs/rebac/
- Adapters: https://casbin.apache.org/docs/adapters/

## Mental Model

Casbin is an embedded authorization library built around:

- a model CONF file: request shape, policy shape, effect, role definitions, matcher
- a policy source: CSV, database adapter, custom adapter, or management API
- an enforcer: application code calls `Enforce(...)` with request arguments

Use Casbin when application code can own enforcement locally and the authorization model can be expressed with matchers over request and policy fields.

## Model CONF Sections

Every Casbin model should make these sections explicit:

```ini
[request_definition]
r = sub, obj, act

[policy_definition]
p = sub, obj, act

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = r.sub == p.sub && r.obj == p.obj && r.act == p.act
```

Add `[role_definition]` for RBAC:

```ini
[role_definition]
g = _, _
```

Use deny override when explicit deny rules exist:

```ini
[policy_definition]
p = sub, obj, act, eft

[policy_effect]
e = some(where (p.eft == allow)) && !some(where (p.eft == deny))
```

Matcher ordering matters. Put cheap equality checks before expensive role or pattern checks when possible:

```ini
[matchers]
m = r.obj == p.obj && r.act == p.act && g(r.sub, p.sub)
```

## RBAC

Model:

```ini
[request_definition]
r = sub, obj, act

[policy_definition]
p = role, obj, act

[role_definition]
g = _, _

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = r.obj == p.obj && r.act == p.act && g(r.sub, p.role)
```

Policy:

```csv
p, viewer, document, read
p, editor, document, read
p, editor, document, update
p, admin, document, delete
g, alice, editor
g, bob, admin
```

Application check:

```text
Enforce("alice", "document", "update") => true
Enforce("alice", "document", "delete") => false
```

Spec notes:

- Treat users, roles, and resources as strings unless the language binding supports typed values in ABAC.
- Model role inheritance deliberately; do not rely on hidden naming conventions.
- Use the RBAC management API for role assignment flows instead of editing CSV by hand in production.

## RBAC With Domains / Tenants

Use domains when a user can have different roles per tenant, organization, or project.

Model:

```ini
[request_definition]
r = sub, dom, obj, act

[policy_definition]
p = role, dom, obj, act

[role_definition]
g = _, _, _

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = r.dom == p.dom && r.obj == p.obj && r.act == p.act && g(r.sub, p.role, r.dom)
```

Policy:

```csv
p, admin, tenant1, document, update
p, viewer, tenant2, document, read
g, alice, admin, tenant1
g, alice, viewer, tenant2
```

Application checks:

```text
Enforce("alice", "tenant1", "document", "update") => true
Enforce("alice", "tenant2", "document", "update") => false
```

Never omit `dom` from a multi-tenant enforcement call. Tenant/domain must come from trusted server context, not from arbitrary client input.

## ABAC

Use ABAC when the matcher needs fields from the subject, object, or request context.

Model:

```ini
[request_definition]
r = sub, obj, act

[policy_definition]
p = sub, obj, act

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = r.sub.Department == r.obj.OwnerDepartment && r.obj.Status != "locked" && r.act == "update"
```

Application check concept:

```text
sub = {Id: "alice", Department: "legal"}
obj = {Id: "doc1", OwnerDepartment: "legal", Status: "draft"}
Enforce(sub, obj, "update") => true
```

ABAC notes:

- Keep attributes server-controlled or fetched by the application before enforcement.
- Use simple matchers; complex business logic is easier to test and audit in a policy engine or domain service.
- For many dynamic conditions, consider OPA or a hybrid design.

## ReBAC

Casbin ReBAC can represent relationship checks through user-resource-role links and resource-type links. Keep the graph shallow unless a dedicated relationship system owns traversal.

Resource role pattern:

```ini
[request_definition]
r = sub, obj, act

[policy_definition]
p = role, obj_type, act

[role_definition]
g = _, _, _
g2 = _, _

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = g(r.sub, r.obj, p.role) && g2(r.obj, p.obj_type) && r.act == p.act
```

Policy:

```csv
p, collaborator, document, read
p, editor, document, update
g, alice, doc1, editor
g, bob, doc1, collaborator
g2, doc1, document
```

For hierarchy inheritance, either:

- materialize inherited relationship roles into policy, e.g. `g, alice, doc1, editor`
- use a role manager or custom function that can answer graph reachability
- move complex graph traversal to a dedicated ReBAC engine or OPA data model

Spec notes:

- State whether relationships are direct or derived.
- Define max traversal depth and cycle behavior.
- Define how reverse audits are answered.

## REST And Route Matching

For API authorization, use path and method fields:

```ini
[request_definition]
r = sub, path, method

[policy_definition]
p = role, path, method

[role_definition]
g = _, _

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = keyMatch2(r.path, p.path) && r.method == p.method && g(r.sub, p.role)
```

Policy:

```csv
p, admin, /tenants/:tenantId/users, POST
p, viewer, /tenants/:tenantId/documents/*, GET
g, alice, admin
```

Do not use route matching as the only tenant boundary. Also verify that `:tenantId` matches the authenticated tenant/domain or an allowed tenant membership.

## Adapters And Storage

Choose storage by operational needs:

- File adapter: tests, examples, local development.
- SQL/ORM adapter: production role and policy management.
- Filtered adapter: large policy sets where each service/tenant loads only a subset.
- Watcher/dispatcher: multi-instance deployments that need policy update propagation.

Implementation checklist:

- Select the language binding and adapter before writing production policy migration scripts.
- Decide whether policy is managed through code, admin UI, API, migrations, or all of them.
- Add integration tests that load the same model and policy format used in production.
- Verify policy persistence after management API calls such as adding roles.
- Log enforcement failures with request tuple, matched model version, and policy version.

## Minimum Test Matrix

For each model file:

- allowed happy path
- denied by default
- denied wrong action
- denied wrong tenant/domain
- denied role missing
- denied explicit deny if using `eft`
- allowed inherited role if inheritance is configured
- ABAC denied missing or mismatched attribute
- ReBAC denied missing relationship
