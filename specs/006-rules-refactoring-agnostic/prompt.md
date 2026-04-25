# Original Prompt

## Rules

Inspecte toutes les rules : aucune ne doit donner d'indication de "comment faire" directement, toutes doivent indiquer un état souhaitable (tu peux mettre des exemple, mais je préfère du pseudo code / GOLANG à un langage spécifique)

La structure attendu pour classifier les rules est:
```bash
mkdir -p .cursor/rules/00-architecture
mkdir -p .cursor/rules/01-standards
mkdir -p .cursor/rules/02-programming-languages
mkdir -p .cursor/rules/03-frameworks-and-libraries
mkdir -p .cursor/rules/04-tools-and-configurations
mkdir -p .cursor/rules/05-workflows-and-processes
mkdir -p .cursor/rules/06-templates-and-models
mkdir -p .cursor/rules/07-quality-assurance
mkdir -p .cursor/rules/08-domain-specific-rules
mkdir -p .cursor/rules/09-other
```
La structure dans le repo est juste rules/*

Hormis dans certaine catégorie qui ciblent les technos, le reste doit être le plus agnostique possible.

Les première rules ont tendance à être très agnostique et à cibler l'architecture filesystème du projet, tandis que d'autre comme programming language et framework-and-libraies cible des extension spcifique / path spécifique

Découpe les rules pour que cela puisse s'appliquer à un globs. Par exemple, créé une rules sur la structure de dossier rules, qui doit nécessairement correspondre

## Skills

En inspectant les rules, tu trouveras peut être des indications de COMMENT faire quelque chose. Cela doit être déplacer dans un SKILL

## Final

n'oublie de mettre à jour le registry, en make sync-registry et et solvant les erreurs

Apelle l' /implementer pour écrire le contenu de la spec
