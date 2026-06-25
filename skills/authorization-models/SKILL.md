---
name: authorization-models
description: Centralize authorization model concepts and implementation guidance for RBAC, ABAC, ReBAC, ACL, PBAC/policy-as-code, OPA, and Apache Casbin. Use when designing access-control specs, choosing an authorization model, writing authorization architecture decisions, or implementing/configuring OPA Rego policies or Casbin models, policies, adapters, and enforcers.
---

# Authorization Models

Use this skill to turn authorization requirements into an explicit model, data shape, policy engine choice, and verification plan.

## Workflow

1. Separate authentication from authorization. Authentication proves who the caller is; authorization decides what that caller can do on which resource, in which context.
2. Extract authorization facts from the product language:
   - subjects: users, service accounts, agents, teams, organizations
   - resources: tenants, projects, folders, documents, records, API routes
   - actions: read, create, update, delete, approve, invite, export
   - context: tenant, ownership, environment, time, status, plan, risk, request path
3. Choose the smallest model that represents the facts without role explosion:
   - ACL: per-resource allowlists for small, explicit sharing cases.
   - RBAC: job functions and coarse permissions.
   - RBAC with domains: same user can have different roles per tenant/project.
   - ABAC: decisions depend on subject/resource/action/environment attributes.
   - ReBAC: decisions depend on graph relationships and hierarchy inheritance.
   - PBAC / policy-as-code: rules must be versioned, reviewed, tested, and deployed independently from application code.
4. Decide enforcement placement:
   - In-process library when latency and simple application ownership matter.
   - Sidecar/service policy decision point when many services need shared policy.
   - Gateway/admission/webhook when enforcement belongs at the platform boundary.
5. Document source-of-truth ownership for every authorization datum: identity provider claims, app database, policy file, relationship store, feature flag, billing system, or request context.

## Reference Loading

Load only the needed references:

- For model selection, tradeoffs, and examples, read `references/concepts.md`.
- For OPA/Rego design, bundle config, REST decisions, and external data, read `references/opa/implementation.md`.
- For Apache Casbin model CONF files, policies, domains, ABAC/ReBAC patterns, adapters, and enforcers, read `references/casbin/implementation.md`.

## Output Contract

When producing a spec or solution, include:

- the selected model(s) and why simpler models are insufficient
- a normalized request tuple, e.g. `{subject, action, resource, context}`
- the policy data needed at decision time
- where policy, roles, attributes, and relationships are stored
- default decision (`deny` unless a rule allows)
- enforcement points and failure behavior
- test cases for allowed, denied, tenant-boundary, missing-data, and stale-data cases
- migration notes if moving from hard-coded checks, ACLs, or simple RBAC

## Engine Guidance

Prefer Casbin when the project needs an embedded authorization library with clear model files and policy storage, especially RBAC, tenant-scoped RBAC, ACL-like rules, route matching, and moderate ABAC.

Prefer OPA when the project needs policy-as-code across services, richer contextual policy, central policy distribution, bundles, audit-friendly Rego tests, or non-application use cases such as gateways, Kubernetes, CI/CD, or infrastructure validation.

Use both only when boundaries are explicit: for example Casbin in one application for fast local enforcement, and OPA at the platform/API boundary for cross-service policy.
