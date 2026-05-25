# Original Prompt — `/specify`

**Date**: 2026-05-22
**Author**: Guilhem Heinrich
**Command**: `/specify`

---

Je veux ajouter un mécanisme de hook pour claude et pour cursor, pour jouer le linter à l'édition / création de fichier.
Le hook se base sur une commande générique dans le make file, qui lui est resposnable d'appeler le bon outil dans le bon container.

Voici un retour de codex sur ce sujet (appliqué pour claude):

> Oui, je te confirme : d'après la doc officielle Claude Code, le bon point d'accroche pour "après édition de fichier, lancer un lint/check déterministe" est bien `PostToolUse` avec un matcher sur les outils d'écriture.
>
> La doc donne même l'exemple explicite :
>
> ```json
> {
>   "hooks": {
>     "PostToolUse": [
>       {
>         "matcher": "Edit|Write",
>         "hooks": [
>           {
>             "type": "command",
>             "command": "/path/to/lint-check.sh"
>           }
>         ]
>       }
>     ]
>   }
> }
> ```
>
> Source : docs Claude Code hooks, section matcher patterns et exemple lint sur `Edit|Write` : <https://code.claude.com/docs/en/hooks>
>
> Petite correction : je dirais `Edit|Write`, pas seulement `Edit`, parce que `Write` couvre la création/remplacement de fichier. La doc actuelle liste `Edit` et `Write`; je n'ai pas vu `MultiEdit` dans cette page. Donc pour coller à la doc : `matcher: "Edit|Write"`.
>
> Ton intuition d'architecture est bonne :
>
> 1. Le hook reste générique et déterministe.
> 2. Le repo porte la configuration applicative.
> 3. Le hook extrait le fichier touché depuis `.tool_input.file_path`.
> 4. Il applique des règles simples : include/exclude, extension, repo root, debounce éventuel.
> 5. Il appelle toujours un point d'entrée stable :
>
> ```bash
> make lint FILE="path/relative/to/file"
> ```
>
> Et c'est le `Makefile` qui sait quoi faire : quel package du monorepo, quel service Docker, quelle image, quel linter, quel mapping de volumes, etc.
>
> Dans votre contexte, je structurerais ça comme ça :
>
> ```json
> {
>   "hooks": {
>     "PostToolUse": [
>       {
>         "matcher": "Edit|Write",
>         "hooks": [
>           {
>             "type": "command",
>             "command": "${CLAUDE_PLUGIN_ROOT}/hooks/lib/lint-on-edit.sh",
>             "async": true,
>             "timeout": 300
>           }
>         ]
>       }
>     ]
>   }
> }
> ```
>
> Puis `lint-on-edit.sh` ferait uniquement l'orchestration neutre :
>
> ```bash
> FILE=$(jq -r '.tool_input.file_path // empty')
> REL_FILE=...
> make lint FILE="$REL_FILE"
> ```
>
> Le `Makefile`, lui, centralise la vérité :
>
> ```make
> lint:
> 	docker compose run --rm app sh -lc 'biome check "$$FILE"'
> ```
>
> Pour un monorepo, `make lint FILE=apps/foo/src/a.ts` peut router vers le bon container/package via une table ou un script local. C'est exactement la bonne séparation : **hook = déclencheur déterministe**, **Makefile = logique métier/env**, **Docker = environnement reproductible**.
>
> Deux nuances importantes :
>
> - `PostToolUse` se déclenche après les outils Claude `Edit|Write`, pas après n'importe quelle modification disque faite par une commande `Bash`. Pour ça, `FileChanged` existe, mais la doc dit que son matcher surveille des noms de fichiers littéraux, donc ce n'est pas idéal pour "tous les fichiers source".
> - Si `async: true`, Claude continue immédiatement et le retour arrive plus tard. Pour du feedback bloquant immédiat, il faut le laisser synchrone, mais ça risque de rendre chaque edit lent. Pour un lint-on-edit, je choisirais plutôt async + debounce/cache côté script.

Propose donc une implémentation, incluant la création d'un skill pour "proprement" écrire le makefile. Attention, si il n'y a pas de linter de configurer par exemple pour un fichier ts (par exemple il manque une commande npm lint dans le container), il faut que le hook block / fasse un retour au llm. Le makefile sert de "router" de container + commande.
