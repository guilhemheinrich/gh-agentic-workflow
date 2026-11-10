# Blocage template: proposal

Workspace-level Linear issue template « Blocage ». Applies the Type label
**Blocage** and asks for a **Destinataire** label. Title prefix: « Blocage : ». Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).
Starts from the existing Blocage template; the act asked for and the date after which waiting costs become explicit.

```markdown
## En clair, avec un exemple

<Ce qui est arrêté, pour qui, et un cas concret. Ex. : « La nouvelle version ne peut pas partir en production tant que l'équipe infra ne nous donne pas l'accès. »>

## Ce qui doit être fait

L'acte attendu, en une phrase : un accès, un livrable, une intervention. Le compte ou la ressource concernés.

## Qui doit agir

Nom, rôle ou équipe (label Destinataire). Ce ticket est créé dans l'équipe qui doit agir.

## Qui attend

Les issues en attente, reliées en « bloquée par » ce ticket.

## À partir de quand ça coûte

JJ/MM, et ce que l'attente coûte au-delà.

## Façon de faire suggérée

Votre proposition, ou « aucune ».

## Contenu de l'échange

Ce qui a été dit, avec la date et les personnes.
```
