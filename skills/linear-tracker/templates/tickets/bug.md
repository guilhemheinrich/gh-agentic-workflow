# Bug template: proposal

Workspace-level Linear issue template « Bug ». Applies the Type label
**Bug**. Title prefix: none. Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).
Starts from the existing Bug template; adds « En clair » and « Promesse ».

```markdown
## En clair, avec un exemple

<Ce que l'utilisateur ne peut plus faire, et un cas concret. Ex. : « L'export d'une facture sans ligne renvoie une erreur au lieu d'un fichier vide. »>

## Promesse

<La source qui dit ce qui devait se passer : spec, contrat d'API, doc, ou comportement d'avant. Sans source, ce n'est pas un bug.>

## Reproduction

1. …
2. …

## Attendu

Ce qui devrait se passer, d'après la promesse.

## Observé

Ce qui se passe réellement : la réponse ou le message exact.

## Environnement

* Environnement et version :
* URL ou écran :
* Utilisateur / rôle :

## Impact

Sévérité, nombre d'utilisateurs touchés, contournement éventuel.

## Logs / captures

## Preuve de correction

Le scénario qui échoue avant correction et son résultat après, sur une version identifiée.
```
