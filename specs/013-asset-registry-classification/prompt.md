# Original prompt — /specify

> Captured verbatim. Used as the source of truth for spec.md.

Refactoriser `asset-registry.yml` et son schema pour rendre la sélection d'assets beaucoup plus claire lors du bootstrap d'un projet.

Contexte:
Le repo contient trois types principaux d'assets:

- Skill: décrit COMMENT faire quelque chose.
- Command: décrit un OBJECTIF à atteindre.
- Rule: décrit une STRUCTURE / un ÉTAT à respecter.

Le fichier `asset-registry.yml` sert à retrouver facilement un ensemble de rules / skills / commands / agents pour initialiser ou enrichir un projet. Aujourd'hui, la taxonomie repose presque uniquement sur les tags. Elle est devenue trop granulaire: beaucoup de tags ont un seul item, certains assets ont trop de tags, et des notions différentes sont mélangées au même niveau (`common`, frameworks, outils, domaines, workflows, qualité, etc.).

Objectif:
Introduire une classification plus simple avec trois niveaux distincts:

1. `category`: navigation principale, obligatoire et unique.
2. `bundles`: presets optionnels pour bootstrap, par exemple `common`.
3. `tags`: recherche fine optionnelle, avec moins de tags et une sémantique plus stricte.

La catégorie doit s'aligner sur la structure existante du dossier `rules/`:

- `architecture`
- `standards`
- `programming-languages`
- `frameworks-and-libraries`
- `tools-and-configurations`
- `workflows-and-processes`
- `templates-and-models`
- `quality-assurance`
- `domain-specific`
- `other`

`common` ne doit plus être traité comme un tag thématique. Il doit devenir un bundle/preset indiquant qu'un asset fait partie du socle recommandé pour presque tous les projets.

Exemple attendu:

```yaml
assets:
  - path: rules/04-tools-and-configurations/4-docker.mdc
    type: rule
    category: tools-and-configurations
    bundles:
      - common
    tags:
      - docker
    description: ...
```

Règles de conception:

- `category` est obligatoire pour tous les assets.
- Un asset a exactement une catégorie.
- `bundles` est optionnel, liste unique, et sert à sélectionner des ensembles installables.
- `tags` reste optionnel ou obligatoire selon la décision de conception, mais doit être limité à des labels utiles pour la recherche fine.
- Les tags ne doivent plus servir à représenter la navigation principale.
- Les tags ne doivent plus contenir des concepts qui relèvent d'un bundle (`common`) ou d'une catégorie (`quality`, `architecture`, etc.), sauf justification explicite.
- Pour les assets sous `rules/`, la catégorie doit être cohérente avec le dossier parent.
- Le schema JSON doit valider les nouvelles propriétés.
- Le registre doit rester éditable humainement et exploitable par VS Code YAML.
- La migration doit éviter les catégories à un seul item quand une catégorie existante convient.
- Les tags non déclarés, orphelins ou quasi-duplicats doivent être nettoyés ou fusionnés.

À spécifier:

- Le nouveau modèle de données YAML.
- Le nouveau JSON Schema.
- La stratégie de migration depuis le registre actuel.
- Les règles de validation.
- La définition précise du bundle `common`.
- Une recommandation sur les bundles additionnels possibles, sans les imposer si le besoin n'est pas encore clair.
- Les critères d'acceptation permettant de vérifier que le registre est plus simple et cohérent.

Critères d'acceptation:

- Chaque asset possède un `category` valide.
- `common` n'apparaît plus dans `tags`.
- Les assets destinés au bootstrap minimal d'un projet utilisent `bundles: [common]`.
- Les tags sont cohérents avec une liste déclarée et documentée.
- Aucun tag utilisé n'est absent du schema.
- Aucun tag déclaré n'est inutilisé, sauf justification documentée.
- Les assets sous `rules/XX-*` ont une catégorie correspondant au dossier.
- Le schema refuse les catégories inconnues, les bundles inconnus, les tags inconnus, les doublons, et les propriétés non prévues.
- Le registre permet trois usages simples:
  1. lister tous les assets d'une catégorie;
  2. installer le bundle `common`;
  3. filtrer finement par tag technique ou domaine.
