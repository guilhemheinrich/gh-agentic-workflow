# OpenAPI Generator CLI Reference

Utiliser cette reference quand il faut produire une commande concrete, expliquer les variantes Docker/npm, ou choisir les options d'un generateur.

## Sources Officielles

- Installation CLI, npm, Docker, JAR: https://openapi-generator.tech/docs/installation/
- Usage CLI, `help`, `list`, `validate`, `generate`: https://openapi-generator.tech/docs/usage/
- Liste des generateurs disponibles: https://openapi-generator.tech/docs/generators/
- Options du generateur `typescript-fetch`: https://openapi-generator.tech/docs/generators/typescript-fetch/

## Docker

Generation TypeScript Fetch:

```bash
docker run --rm \
  -v "${PWD}:/local" \
  openapitools/openapi-generator-cli generate \
  -i /local/openapi.yaml \
  -g typescript-fetch \
  -o /local/generated/client \
  --additional-properties=npmName=@my-org/api-client,npmVersion=0.1.0
```

Generation Python:

```bash
docker run --rm \
  -v "${PWD}:/local" \
  openapitools/openapi-generator-cli generate \
  -i /local/openapi.yaml \
  -g python \
  -o /local/generated/python-client
```

Generation Go:

```bash
docker run --rm \
  -v "${PWD}:/local" \
  openapitools/openapi-generator-cli generate \
  -i /local/openapi.yaml \
  -g go \
  -o /local/generated/go-client \
  --additional-properties=packageName=apiclient
```

Commandes auxiliaires Docker:

```bash
docker run --rm -v "${PWD}:/local" openapitools/openapi-generator-cli validate -i /local/openapi.yaml
docker run --rm openapitools/openapi-generator-cli list
docker run --rm openapitools/openapi-generator-cli config-help -g typescript-fetch
```

## npm

Installation locale:

```bash
npm install @openapitools/openapi-generator-cli -D
```

Generation TypeScript Fetch:

```bash
npx @openapitools/openapi-generator-cli generate \
  -i openapi.yaml \
  -g typescript-fetch \
  -o generated/client \
  --additional-properties=npmName=@my-org/api-client,npmVersion=0.1.0
```

Generation Python:

```bash
npx @openapitools/openapi-generator-cli generate \
  -i openapi.yaml \
  -g python \
  -o generated/python-client
```

Generation Go:

```bash
npx @openapitools/openapi-generator-cli generate \
  -i openapi.yaml \
  -g go \
  -o generated/go-client \
  --additional-properties=packageName=apiclient
```

Commandes auxiliaires npm:

```bash
npx @openapitools/openapi-generator-cli validate -i openapi.yaml
npx @openapitools/openapi-generator-cli list
npx @openapitools/openapi-generator-cli config-help -g typescript-fetch
```

Script `package.json` recommande pour un projet web:

```json
{
  "scripts": {
    "generate:api-client": "openapi-generator-cli generate -i openapi.yaml -g typescript-fetch -o generated/client --additional-properties=npmName=@my-org/api-client,npmVersion=0.1.0"
  },
  "devDependencies": {
    "@openapitools/openapi-generator-cli": "<version-pinnee>"
  }
}
```

Remplacer `<version-pinnee>` par la version choisie par l'equipe, ou conserver la version deja presente dans le projet.

## Choix Du Generateur

- Frontend web sans client HTTP impose: `typescript-fetch`.
- Frontend ou Node.js avec Axios deja standardise: `typescript-axios`.
- Backend Python ou distribution SDK Python: `python`.
- Backend Go ou SDK Go: `go`.
- Autre langage: lancer `list`, puis `config-help -g <generateur>`.

## Bonnes Pratiques

- Regenerer depuis la specification source, pas depuis du code genere modifie a la main.
- Garder les patches manuels hors du dossier genere; preferer templates custom ou wrappers applicatifs.
- Ajouter le dossier genere au controle de version seulement si l'equipe veut versionner le SDK produit.
- Pinner la version de l'image Docker ou du wrapper en CI pour eviter les diffs de generation surprises.
- Lire les options du generateur cible avec `config-help` avant d'ajouter `--additional-properties`.
