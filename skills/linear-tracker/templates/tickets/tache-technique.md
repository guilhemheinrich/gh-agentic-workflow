# Tâche technique template: proposal

Workspace-level Linear issue template « Tâche technique ». Applies the Type label
**Tâche technique**. Title prefix: none. Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).
Starts from the existing Tâche technique template; adds « En clair » and the definition of done.

```markdown
## En clair, avec un exemple

<Pourquoi ce travail, en termes de produit. Ex. : « Node 20 n'est plus maintenu : on monte le service en Node 22 pour continuer à recevoir les correctifs de sécurité. »>

## Issue produit

Lien de l'issue produit, en relation parent ou « liée à ». « Aucune » pour de la dette ou de l'outillage.

## Spécification

Lien et version de la spec du JJ/MM.

## À faire

* …

## Terminé quand

Mergé en staging, pipeline de merge vert. Le ticket s'arrête là : montrer que ça tourne est le travail d'une Preuve.

## Preuve conseillée

Lien vers le ticket Preuve qui montrera que ça tourne sur staging (une commande et sa sortie, ou une capture), ou « aucune » et pourquoi.
```
