# Preuve template: proposal

Workspace-level Linear issue template « Preuve ». Applies the Type label
**Preuve**. Title prefix: « Preuve : ». Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).
New. A Preuve is an execution, not code: a command, or a Playwright or browser
session that takes the screenshot. Each Preuve is blocked by every issue of its
lot, including the code tickets that recommended it, and sits in the lot's milestone.

```markdown
## En clair, avec un exemple

<Ce qu'on prouve, en une phrase qu'un PO comprend. Ex. : « Sur staging, une invitation s'ouvre comme une invitation dans la messagerie. »>

## Ce qui est prouvé

* Environnement : staging | prod
* Lot : <le milestone> — cette preuve est « bloquée par » toutes les issues du lot
* Version attendue : <tag, SHA, ou « celle du dernier merge du lot »>

## Comment le prouver

* Type de preuve : sortie de commande | capture (session Playwright ou navigateur)
* Parcours ou commande : <URL et persona, ou la commande exacte>
* Ce que fait la commande : <en une phrase>
* Résultat attendu : <ce qu'on doit voir, précisément>
* Ex. : `kubectl exec deploy/agenda -- node --version` lit la version de Node dans le pod staging ; attendu : `v22.x`.

Si prouver demande d'écrire du code (un test e2e, un script), ce code est une Tâche technique, et cette Preuve est bloquée par elle.

## Preuve

À poster en commentaire, un commentaire par preuve :

* Capture : l'écran sur l'environnement, URL visible.
* Commande : la commande, ce qu'elle fait, sa sortie réelle, la date et la version déployée.
* Un extrait de code ne suffit pas : il prouve que le code existe, pas qu'il tourne.

## Validation

* Preuve postée par : <agent ou personne>
* Validée par : <la personne qui a regardé la preuve et ferme le ticket>
```
