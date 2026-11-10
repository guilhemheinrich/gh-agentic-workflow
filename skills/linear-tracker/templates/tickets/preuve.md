# Preuve template: proposal

Workspace-level Linear issue template « Preuve ». Applies the Type label
**Preuve**. Title prefix: « Preuve : ». Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).
New. Each Preuve is blocked by every issue of its lot and sits in the lot's milestone.

```markdown
## En clair, avec un exemple

<Ce qu'on prouve, en une phrase qu'un PO comprend. Ex. : « Sur staging, une invitation s'ouvre comme une invitation dans la messagerie. »>

## Ce qui est prouvé

* Environnement : staging | prod
* Lot : <le milestone> — cette preuve est « bloquée par » toutes les issues du lot
* Version attendue : <tag, SHA, ou « celle du dernier merge du lot »>

## Comment le prouver

* Type de preuve : capture d'écran | sortie de commande
* Parcours ou commande : <URL et persona, ou la commande exacte>
* Ce que fait la commande : <en une phrase>
* Résultat attendu : <ce qu'on doit voir, précisément>

## Preuve

À poster en commentaire, un commentaire par preuve :

* Capture : l'écran sur l'environnement, URL visible.
* Commande : la commande, ce qu'elle fait, sa sortie réelle, la date et la version déployée.
* Un extrait de code ne suffit pas : il prouve que le code existe, pas qu'il tourne.

## Validation

* Preuve postée par : <agent ou personne>
* Validée par : <la personne qui a regardé la preuve et ferme le ticket>
```
