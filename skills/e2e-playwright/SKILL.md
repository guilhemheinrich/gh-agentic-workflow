---
name: e2e-playwright
description: >-
  End-to-end testing with Playwright using a dedicated Docker Compose
  environment. Use when setting up E2E tests, writing Playwright specs,
  configuring test infrastructure, or debugging E2E CI pipelines.
tags:
  - docker
  - e2e
  - testing
---

# E2E Testing — Playwright + Docker Compose

Pattern complet pour les tests end-to-end avec Playwright, orchestrés via un fichier `compose.e2e.yml` dédié.

**Template de référence :** [`references/compose.e2e.yml`](./references/compose.e2e.yml)

---

## Principes fondamentaux

| Principe | Détail |
|:---|:---|
| **Idempotence** | Chaque test peut être exécuté N fois sans effet de bord. L'état est créé au setup et nettoyé au teardown. |
| **Parallélisme** | Plusieurs utilisateurs de test distincts sont provisionnés — un par fichier de spec — pour permettre l'exécution parallèle sans collision. |
| **Isolation** | L'environnement de test est entièrement défini via Docker Compose — jamais sur le host. |
| **Reproductibilité** | Variables d'environnement contrôlent le timing et le mode vidéo pour des résultats déterministes. |

---

## Architecture de l'environnement

### Stratégie Compose : base + override

Le service `playwright` est déclaré dans le `compose.yml` principal sous un **profil `e2e`** (non démarré par défaut). Le fichier `compose.e2e.yml` ne contient que les **surcharges d'environnement** spécifiques au mode E2E :

```bash
# Lancer les tests E2E
docker compose -f compose.yml -f compose.e2e.yml --profile e2e up --build --abort-on-container-exit --exit-code-from playwright
```

### compose.yml — service playwright (profil e2e)

```yaml
services:
  # ... (app, db, etc.)

  playwright:
    build:
      context: .
      dockerfile: .docker/e2e/Dockerfile
    container_name: ${APP_SLUG}-playwright
    volumes:
      - ./apps/e2e:/app
      - /app/node_modules
    environment:
      BASE_URL: http://frontend:3101
    networks:
      - app-network
    depends_on:
      - frontend
      - backend
    profiles:
      - e2e
```

### compose.e2e.yml — overrides uniquement

Ce fichier ne redéfinit **que** les variables d'environnement qui changent en mode E2E :

```yaml
services:
  backend:
    environment:
      NODE_ENV: test
      HUB_AUTH_URL: ""
      CHAT_LLM_PROVIDER: "${CHAT_LLM_PROVIDER:-fake}"

  playwright:
    environment:
      SLOW_MO: "${E2E_ACTION_DELAY_MS:-50}"
      PW_VIDEO: "${E2E_VIDEO_MODE:-off}"
      WORKERS: "${E2E_WORKERS:-4}"
```

Voir le **template complet** : [`references/compose.e2e.yml`](./references/compose.e2e.yml)

### Variables d'environnement

| Variable | Default | Description |
|:---|:---|:---|
| `E2E_ACTION_DELAY_MS` | `50` | Délai entre les actions Playwright (ms). Augmenter pour le debug visuel (500-1000). |
| `E2E_VIDEO_MODE` | `off` | Mode vidéo Playwright : `off`, `on`, `retain-on-failure`, `on-first-retry` |
| `E2E_WORKERS` | `4` | Nombre de workers parallèles |

Ces variables peuvent être définies directement dans le `compose.e2e.yml` ou via un fichier `.env.e2e`.

---

## Configuration Playwright

### playwright.config.ts

```typescript
import { defineConfig, devices } from '@playwright/test';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:3000';
const SLOW_MO = process.env.CI ? 0 : Number(process.env.SLOW_MO ?? 50);

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 1,
  workers: Number(process.env.WORKERS) || undefined,

  reporter: [
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
    ['json', { outputFile: 'playwright-report/results.json' }],
    ['list'],
  ],

  use: {
    baseURL: BASE_URL,
    actionTimeout: 10_000,
    navigationTimeout: 30_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: {
      mode: (process.env.PW_VIDEO as 'off' | 'on' | 'retain-on-failure' | 'on-first-retry') || 'off',
      size: { width: 1280, height: 720 },
    },
    launchOptions: {
      slowMo: SLOW_MO,
    },
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'firefox',
      use: { ...devices['Desktop Firefox'] },
    },
    {
      name: 'webkit',
      use: { ...devices['Desktop Safari'] },
    },
  ],

  timeout: 60_000,
  expect: { timeout: 10_000 },
});
```

### .gitignore

Ajouter systématiquement à la racine du projet :

```gitignore
# E2E reports
playwright-report/
```

---

## Rapports de sortie

Les rapports sont **toujours** générés dans `playwright-report/` à la racine du projet (ou du package e2e) :

```
playwright-report/
├── index.html         # Rapport HTML interactif (humains)
├── results.json       # Rapport JSON structuré (LLMs, CI, analyse automatique)
└── test-results/      # Artefacts (screenshots, vidéos, traces)
```

Le format **JSON** est obligatoire en complément du HTML : il permet l'analyse automatisée par les LLMs et l'intégration CI.

---

## Gestion des utilisateurs de test

### Principe : un utilisateur par fichier de spec

Chaque fichier de spec reçoit un utilisateur de test **dédié**, éliminant toute collision même en exécution parallèle :

```typescript
// fixtures/test-users.ts

const E2E_USER_COUNT = 20;

type E2eUserKey = `e2e-test-${string}`;

interface E2eUser {
  email: string;
  displayName: string;
}

const E2E_USERS: Record<E2eUserKey, E2eUser> = Object.fromEntries(
  Array.from({ length: E2E_USER_COUNT }, (_, i) => {
    const num = String(i + 1).padStart(2, '0');
    const key: E2eUserKey = `e2e-test-${num}`;
    return [key, { email: `e2e-test-${num}@test.local`, displayName: `E2E Tester ${num}` }];
  }),
) as Record<E2eUserKey, E2eUser>;
```

### Attribution par fichier de spec

```typescript
// fixtures/auth.fixture.ts

export const FILE_USER_MAP: Record<string, DevUserKey> = {
  'auth.spec.ts': 'e2e-test-01',
  'calendar.spec.ts': 'e2e-test-02',
  'event-create.spec.ts': 'e2e-test-03',
  // ... un mapping par fichier de test
};

function resolveFileUser(testFilePath: string): DevUserKey {
  const fileName = testFilePath.split('/').pop() ?? '';
  return FILE_USER_MAP[fileName] ?? 'e2e-test-01';
}

export const test = base.extend<AuthFixtures>({
  testUser: async ({}, use, testInfo) => {
    const user = resolveFileUser(testInfo.file);
    await use(user);
  },

  authenticatedPage: async ({ page, testUser }, use) => {
    await login(page, testUser);
    await use(page);
  },
});
```

---

## Setup & Teardown

### Stratégie

| Phase | Responsabilité |
|:---|:---|
| **Global Setup** | Provisionner les utilisateurs de test + seed des données de base |
| **Per-test cleanup** | Chaque test nettoie les données qu'il a créées (via `afterEach` ou fixture teardown) |
| **Global Teardown** | Supprimer tous les utilisateurs de test et leurs données associées |

### Global Setup — provisionnement

```typescript
// global-setup.ts
import { FullConfig } from '@playwright/test';

export default async function globalSetup(config: FullConfig) {
  const baseURL = config.projects[0].use.baseURL!;

  // Cleanup avant provision (idempotence)
  await fetch(`${baseURL}/api/test/reset`, { method: 'POST' });

  // Provisionner les utilisateurs E2E
  await fetch(`${baseURL}/api/test/seed`, { method: 'POST' });
}
```

### Global Teardown — nettoyage complet

```typescript
// global-teardown.ts
import { FullConfig } from '@playwright/test';

export default async function globalTeardown(config: FullConfig) {
  const baseURL = config.projects[0].use.baseURL!;

  // Supprimer utilisateurs de test + données associées (events, preferences, etc.)
  await fetch(`${baseURL}/api/test/cleanup`, { method: 'POST' });
}
```

### Alternative : script de cleanup DB

Pour les projets avec Prisma/TypeORM, un script de cleanup direct sur la DB est souvent plus fiable :

```bash
# Dans le Makefile / commande pré-test
docker compose exec backend bun run prisma/e2e-cleanup.ts
```

### Référencement dans la config

```typescript
// Dans playwright.config.ts
export default defineConfig({
  globalSetup: require.resolve('./global-setup'),
  globalTeardown: require.resolve('./global-teardown'),
  // ...
});
```

---

## Commandes d'exécution

Toujours via Docker Compose, jamais sur le host :

```bash
# Lancer les tests E2E (build + run + exit)
docker compose -f compose.yml -f compose.e2e.yml --profile e2e up --build --abort-on-container-exit --exit-code-from playwright

# Avec vidéo activée
E2E_VIDEO_MODE=on docker compose -f compose.yml -f compose.e2e.yml --profile e2e up --build --abort-on-container-exit --exit-code-from playwright

# Avec délai augmenté (debug visuel)
E2E_ACTION_DELAY_MS=800 docker compose -f compose.yml -f compose.e2e.yml --profile e2e up --build --abort-on-container-exit --exit-code-from playwright

# Nettoyer l'environnement
docker compose -f compose.yml -f compose.e2e.yml --profile e2e down -v
```

---

## Dockerfile.e2e

```dockerfile
FROM mcr.microsoft.com/playwright:v1.52.0-noble

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY playwright.config.ts ./
COPY tests/ ./tests/
COPY fixtures/ ./fixtures/

CMD ["npx", "playwright", "test"]
```

---

## Bonnes pratiques

### Idempotence des tests

- **Jamais** de dépendance entre tests : chaque test crée ses propres données via le setup.
- Les données créées pendant un test sont nettoyées **dans le test lui-même** (`afterEach` ou fixture teardown), pas seulement au global teardown.
- Le global setup commence par un **reset** pour garantir un état propre même si le teardown précédent a échoué.
- Utiliser des identifiants uniques (UUID, timestamp) pour les entités créées pendant les tests.

### Parallélisme

- Un utilisateur de test par fichier de spec. Pas de partage d'état entre fichiers.
- Les tests au sein d'un même fichier partagent le même utilisateur (exécution séquentielle intra-fichier).
- Les fichiers de test sont parallélisés (`fullyParallel: true`).
- Prévoir un pool d'utilisateurs suffisant (20 minimum) pour absorber la croissance des specs.

### CI/CD

```yaml
# Exemple GitHub Actions
e2e-tests:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Run E2E tests
      run: docker compose -f compose.yml -f compose.e2e.yml --profile e2e up --build --abort-on-container-exit --exit-code-from playwright
    - name: Upload report
      if: always()
      uses: actions/upload-artifact@v4
      with:
        name: playwright-report
        path: playwright-report/
```

---

## Checklist de mise en place

- [ ] Déclarer le service `playwright` dans `compose.yml` avec `profiles: [e2e]`
- [ ] Créer `compose.e2e.yml` avec les overrides d'environnement E2E
- [ ] Créer `Dockerfile.e2e` (ou `.docker/e2e/Dockerfile`) pour le runner Playwright
- [ ] Configurer `playwright.config.ts` avec les 3 navigateurs + rapports JSON/HTML
- [ ] Ajouter `playwright-report/` au `.gitignore`
- [ ] Créer le pool d'utilisateurs de test (≥ 20)
- [ ] Implémenter `FILE_USER_MAP` — un utilisateur dédié par fichier de spec
- [ ] Implémenter le provisionnement (global-setup ou script de seed)
- [ ] Implémenter le nettoyage complet (global-teardown ou script de cleanup)
- [ ] Exposer un endpoint `/api/test/*` (protégé, uniquement en `NODE_ENV=test`)
- [ ] Vérifier l'idempotence : exécuter les tests 2x de suite sans échec
