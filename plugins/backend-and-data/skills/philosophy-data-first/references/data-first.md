# Data-First & State Transitions — content to insert into PHILOSOPHY.md

> Insert this block into `PHILOSOPHY.md` (see the skill's "PHILOSOPHY.md
> procedure"). Replace each "to be decided" with the decision taken with the
> human.

## Adopted philosophies

- **Data-First & State Transitions** — data drives the feature: every feature
  is a transactional, database-verifiable state transition, never a mere
  "form" or "endpoint".

## 1. Principles

1. **The database is the source of truth of state; code is the author of
   transitions.** Critical invariants are guaranteed by the database
   (constraints, foreign keys, `CHECK`, uniqueness), not only by code. Code
   computes and transforms; every piece of business logic ends in an explicit,
   verifiable state transition.
2. **One use case = one atomic transaction.** It is defined by a trigger, an
   initial state (preconditions) and a committed final state. If the
   preconditions are not met, nothing is written.
3. **No external I/O inside a transaction.** Every async or external effect
   (API call, email, outgoing webhook) goes through a **job enqueued in the
   same transaction** as the business data, via the chosen orchestrator (§3).
   Each job is itself a use case with its own trigger, initial state and final
   state (e.g. `email_status: PENDING → SENT | FAILED`).
4. **The final state is always a committed state; outputs are consequences:**
   - synchronous response (HTTP / callback) → read from the committed state;
   - outgoing external effect → enqueued job, then the job's use case;
   - internal mutation only → transaction commit.
5. **Incoming webhooks are persisted first**, then processed by a job.
6. **Jobs are idempotent** (at-least-once delivery); outgoing calls carry an
   idempotency key.
7. **Concurrency is explicit:** each transition declares its protection
   (`SELECT … FOR UPDATE`, version column, unique constraint).
8. **Stored derived values are qualified:** *frozen snapshot* (e.g. price at
   order time) or *recomputable value* (projection).
9. **Reads are not mutation use cases:** they are projections of the state.
10. **Data access exploits the physical model.** The ORM / query builder must
    expose the real schema (types, constraints, enums, indexes, transactions)
    rather than hide it; whatever it cannot express is written in SQL in the
    migration, never dropped.

## 2. Mandatory formats

Every feature spec, issue or major prompt describes each use case this way.
Mutations are described conceptually (`table.field: A → B`), not in SQL.

### Use case template (state transition)

- **Name:** `verb_entity` (e.g. `confirm_cart`)
- **Trigger:** user action | cron | incoming webhook | job
- **Preconditions (initial state):**
  - `carts.status` = `PENDING`
  - the user has an active row in `subscriptions`
- **Transitions (mutations):**
  - `carts.status`: `PENDING → CONFIRMED`
  - `orders`: one row created (`cart_id`, `total_amount` = frozen snapshot)
- **Invariants guaranteed after commit:** <constraints that must hold>
- **Jobs enqueued (same transaction):** `send_confirmation` —
  payload `{ order_id }`, idempotency key `order_id`
- **Synchronous output:** <HTTP response / callback, read from committed state>
- **Failures:** <unmet precondition → error returned, no state change>
- **Concurrency:** <lock / version / constraint>
- **Example:**
  - *State before (JSON or DB mock):* …
  - *Action:* …
  - *State after (JSON or DB mock):* …

## 3. Implementation decisions

| Decision | Choice | Criterion | Date |
|---|---|---|---|
| Job orchestrator | to be decided | Enqueue must share the business transaction; otherwise an outbox table is mandatory | |
| ORM / query builder | to be decided | Exposes the physical model (constraints, enums, indexes, typed transactions) and yields readable SQL migrations | |
