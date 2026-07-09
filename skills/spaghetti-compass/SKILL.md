---
name: spaghetti-compass-exploration
description: >
  Explorer et raconter du code avec le CLI spaghetti-compass. Trois cas d'usage :
  (1) en revue, lancer l'analyse d'impact inverse sur les fichiers modifiés pour
  savoir quelles routes re-tester ; (2) explorer efficacement les dépendances et
  le graphe d'appels avant un refactoring ; (3) raconter en langage naturel le
  parcours de la donnée (de la requête HTTP jusqu'au bout) avec un lien Ctrl+Click
  vers chaque symbole. À utiliser quand l'utilisateur demande à "reviewer", "voir
  l'impact d'un changement", "refactorer", "explorer les dépendances", "voir qui
  appelle", "détecter les cycles", ou "expliquer / raconter comment marche" un flux.
---

# Spaghetti Compass — explorer, reviewer, raconter le code

Spaghetti-compass s'appuie sur des **LSP** (TypeScript, Intelephense, Pyright, gopls) et des parsers pour donner une **résolution sémantique** (définitions et appels réels, pas du texte), un **graphe de dépendances** transitif, la **détection de cycles**, et l'**analyse d'impact inverse** (qui dépend de ce fichier).

Deux commandes :

- `explore <entry>` — analyse **avant** : depuis un fichier (ou `fichier:fonction`), suit imports et appels.
- `impact <file>` — analyse **inverse** : depuis un fichier cible, trouve tous les fichiers **et les routes** qui en dépendent.

Toutes les sorties exposent des chemins **cliquables** au format `chemin:ligne:colonne` (Ctrl+Click dans VSCode/Cursor). Ajouter `--json` pour toute exploitation programmatique.

## Exécution (hôte vs Docker)

**Priorité hôte** : si **spaghetti-compass** est installé (global ou `npx`), l'utiliser sur la machine hôte — le **LSP** déjà présent au niveau du projet améliore la résolution. **Sinon** (CLI absent ou règle docker-execution), utiliser Docker.

**Sur l'hôte** :
```bash
spaghetti-compass explore <entry> -c <context> [options]
spaghetti-compass impact <file> -c <context> [options]
# ou npx spaghetti-compass ...
```

**Fallback Docker** :
```bash
docker run --rm --user $(id -u):$(id -g) -v "$(pwd)":/app -w /app node:20 npx spaghetti-compass explore <entry> -c <context>
```

- `<entry>` / `<file>` : chemin relatif au repo, ex. `src/core/analyzer.ts` ou `src/services/auth.ts:login`
- `<context>` (`-c`) : répertoire "interne" (ex. `src/` ou `.`) pour classer internal / external / third-party

---

## Cas 1 — En revue : impact des fichiers modifiés

**Quand** : phase de review, ou avant de committer / pousser un changement. Objectif : savoir **quelles routes et quels fichiers** pourraient casser, sans écrire la moindre glue — la commande `impact` suffit.

**Recette** : prendre les fichiers modifiés via git, lancer `impact` sur chacun, lire le champ `routes`.

```bash
# Fichiers modifiés par rapport à la base de la PR (ou HEAD)
for f in $(git diff --name-only origin/main...HEAD); do
  echo "### $f"
  spaghetti-compass impact "$f" -c . --json
done
```

Dans chaque sortie JSON :

- `routes` : les **points d'entrée impactés** (route, handler, cron…) — ce sont eux à re-tester/relire en priorité. Chaque entrée a un `path` cliquable et une `chain` (route → … → fichier modifié) qui explique *pourquoi* la route est touchée.
- `directDependents` : fichiers qui importent directement la cible.
- `dependents` : tous les dépendants transitifs (l'étendue réelle du changement).

**Comment l'exploiter en review** : pour chaque fichier modifié, citer les routes impactées et vérifier que les tests/critères d'acceptation couvrent bien ces points d'entrée. Si `routes` est vide alors que des dépendants existent, soit le changement est purement interne, soit les patterns de route ne matchent pas (voir `--routes` / `config/route-patterns.txt`).

---

## Cas 2 — Explorer le code efficacement

**Quand** : avant un **refactoring** (renommer, déplacer, extraire), pour comprendre un fichier ou une fonction complexe, ou vérifier des **dépendances circulaires**.

**Pourquoi pas grep ?** Grep cherche du texte (et matche commentaires, strings, faux positifs). Spaghetti-compass résout les **vraies** définitions et appels via LSP, suit la transitivité, et signale les cycles.

```bash
# Dépendances d'un fichier (arbre transitif)
spaghetti-compass explore src/main.ts -c src/ --json

# Graphe d'appels d'une fonction / méthode
spaghetti-compass explore src/services/auth.ts:login -c src/ --json
spaghetti-compass explore src/core/Analyzer.ts:Analyzer.analyze -c src/ --json

# Dépendances directes uniquement
spaghetti-compass explore src/main.ts -c src/ --no-transitive --json

# Détecter les cycles
spaghetti-compass explore src/index.ts -c src/ --json
# puis : jq '.stats.circularDependencies'
```

Dans le JSON : `nodes` (fichiers / fonctions / modules externes — id, type, name, path, location), `edges` (from, to, type `import-static` | `import-dynamic` | `call`, resolved), `stats.circularDependencies`, `entryPoint`.

---

## Cas 3 — Raconter le parcours de la donnée en langage naturel

**Quand** : l'utilisateur veut **comprendre / faire comprendre** un flux ("explique comment marche…", "raconte ce qui se passe quand on appelle…"). Objectif : une **histoire en prose**, de la requête HTTP jusqu'au bout (réponse, écriture en base, appel externe), où **chaque phrase ou segment de phrase** est suivi entre parenthèses du **lien Ctrl+Click** vers le symbole qui porte le sens de ce segment.

**Recette** :

1. Trouver le **handler** de la route (le `fichier:fonction` du point d'entrée HTTP).
2. `spaghetti-compass explore <fichier>:<handler> -c <context> --json` pour obtenir le graphe d'appels **dans l'ordre d'exécution** : chaque `node` porte `path` + `line` → c'est le lien à citer.
3. Suivre l'arbre de haut en bas et écrire la prose. Pour chaque étape, coller le lien `chemin:ligne:colonne` du symbole concerné juste après le segment qui le décrit.
4. Si un appel sort vers une autre couche (service → repository → client externe), relancer `explore` sur ce symbole pour continuer l'histoire.

**Règle de style** : le lien suit le **bout de phrase qui exprime l'action de ce symbole**, pas la phrase entière. Préférer une granularité fine (un lien par étape) à un seul lien en fin de paragraphe.

### Exemple — enregistrement d'un utilisateur Hub (route `register`)

> *Les chemins ci-dessous sont illustratifs : remplace-les par ceux que `explore` renvoie réellement pour le projet courant.*

Point de départ :
```bash
spaghetti-compass explore src/modules/auth/auth.controller.ts:AuthController.register -c src/ --json
```

Récit produit :

> Lorsqu'un client envoie un `POST /auth/register`, la requête atteint le handler de la route (src/modules/auth/auth.controller.ts:42:3) qui commence par valider le corps reçu contre le schéma d'inscription (src/modules/auth/dto/register.dto.ts:8:14). Une fois le payload jugé conforme, le contrôleur délègue toute la logique au service d'authentification (src/modules/auth/auth.service.ts:55:3). Ce service vérifie d'abord qu'aucun compte n'existe déjà pour cet email (src/modules/auth/auth.service.ts:61:5), puis hache le mot de passe avant tout stockage (src/modules/auth/auth.service.ts:64:5). Il propage ensuite l'identité au Hub Septeo en appelant l'API d'inscription (src/integrations/hub/hub.client.ts:30:3), ce qui déclenche un `PATCH /v1/register` côté Keycloak (src/integrations/hub/hub.client.ts:34:5). En cas de succès, l'utilisateur est persisté localement avec son identifiant Hub (src/modules/users/users.repository.ts:48:3), un événement "utilisateur enregistré" est émis pour les abonnés (src/modules/auth/auth.service.ts:78:5), et le contrôleur renvoie enfin une réponse 201 décrivant le compte créé (src/modules/auth/auth.controller.ts:50:5).

Chaque segment entre parenthèses est un lien Ctrl+Click : le lecteur saute directement au symbole qui réalise l'action décrite, et l'ordre des liens reflète l'ordre d'exécution donné par le graphe d'appels.

---

## Référence rapide

**Formats d'entrée**

- Fichier seul : `path/to/file.ts`
- Fonction / méthode : `path/to/file.ts:fonction` ou `path/to/file.ts:ClassName.method`

Extensions supportées : `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.py`, `.pyi`, `.php`, `.go`.

**Options utiles**

- `-c, --context <dir>` : répertoire interne pour la classification
- `--json` : sortie machine (à parser avec `jq`)
- `--no-transitive` (explore) : dépendances directes seulement
- `-d, --depth <n>` (explore) : profondeur du graphe d'appels (défaut 5)
- `--routes <glob...>` (impact) : définit les patterns de route (sinon `config/route-patterns.txt`)
- `--no-links` : désactive le format cliquable `chemin:ligne:colonne`

**Schéma JSON `explore`** : `nodes`, `edges`, `stats.circularDependencies`, `entryPoint`.
**Schéma JSON `impact`** : `target`, `routes` (path + chain), `directDependents`, `dependents`, `scannedFiles`, `routePatterns`.
