<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->

## Asset Guidelines

Ce repo contient trois types d'assets distincts. Chacun a un rôle précis :

- **Skill** — décrit **COMMENT** faire quelque chose (procédure, étapes, savoir-faire).
- **Command** — décrit un **OBJECTIF** à atteindre (intention, résultat attendu).
- **Rule** — décrit une **STRUCTURE / un ÉTAT** à respecter (contrainte, invariant, convention).

### Mise à jour obligatoire du registre

Dès qu'un asset est **créé, déplacé, renommé ou supprimé** — et en particulier lors de la **création d'un skill** — il faut **automatiquement** mettre à jour `asset-registry.yml` à la racine du repo, dans le même changement. Ne jamais laisser le registre désynchronisé.

Pour un nouveau skill, ajouter une entrée sous `assets:` :

- `path` : le **dossier** du skill (ex. `skills/lsp-mcp/`), terminé par `/`, pour inclure les fichiers compagnons (`references/`, `scripts/`, `templates/`).
- `type` : `skill`.
- `category` : une des catégories de `x-category-descriptions`.
- `tags` : au moins un tag existant dans `x-tag-descriptions`. **Si un tag pertinent manque**, l'ajouter d'abord à `x-tag-descriptions` (YAML) **et** à l'enum `tag` de `asset-registry.schema.json` (sinon la validation échoue).
- `description` : reprendre le résumé du frontmatter `description` du `SKILL.md`.
- `bundles` : ajouter `common` uniquement si le skill fait partie du starter set minimal et agnostique.

Le registre est validé contre `asset-registry.schema.json` ; vérifier l'absence de diagnostics après modification.
