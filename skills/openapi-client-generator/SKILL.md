---
name: openapi-client-generator
description: Generate API client SDKs from OpenAPI specifications with OpenAPI Generator. Use when Codex needs to create, regenerate, document, or troubleshoot a client from openapi.yaml, openapi.yml, swagger.yaml, or an OpenAPI JSON file, especially with Docker or the npm wrapper @openapitools/openapi-generator-cli.
---

# OpenAPI Client Generator

Utiliser OpenAPI Generator comme outil par defaut pour generer un client depuis une specification OpenAPI. Preferer ce skill quand la demande mentionne `openapi.yaml`, `openapi.yml`, `swagger.yaml`, `-g typescript-fetch`, `-g python`, `-g go`, Docker, npm, ou `@openapitools/openapi-generator-cli`.

## Workflow

1. Localiser la specification (`openapi.yaml`, `openapi.yml`, `swagger.yaml`, `openapi.json`) et verifier son chemin relatif au dossier de travail.
2. Choisir le generateur cible avec le user ou les conventions du projet. Exemples courants: `typescript-fetch`, `typescript-axios`, `python`, `go`, `java`, `csharp`.
3. Valider la specification avant generation quand c'est possible.
4. Generer dans un dossier dedie (`generated/client`, `clients/<lang>`, `packages/api-client`) pour eviter d'ecraser du code applicatif.
5. Inspecter le README et les fichiers generes avant integration: dependances, nom de package, version, exports, format ESM/CJS, et conventions de build.
6. En CI, pinner la version d'OpenAPI Generator ou de l'image Docker afin d'obtenir des sorties reproductibles.

## Commandes Docker

Utiliser Docker quand Java ne doit pas etre installe sur la machine hote.

```bash
docker run --rm \
  -v "${PWD}:/local" \
  openapitools/openapi-generator-cli generate \
  -i /local/openapi.yaml \
  -g typescript-fetch \
  -o /local/generated/client \
  --additional-properties=npmName=@my-org/api-client,npmVersion=0.1.0
```

Valider ou lister les generateurs avec le meme conteneur:

```bash
docker run --rm -v "${PWD}:/local" openapitools/openapi-generator-cli validate -i /local/openapi.yaml
docker run --rm openapitools/openapi-generator-cli list
docker run --rm openapitools/openapi-generator-cli config-help -g typescript-fetch
```

## Commandes npm

Utiliser le wrapper npm quand le projet JavaScript/TypeScript veut garder la generation dans ses scripts.

```bash
npm install @openapitools/openapi-generator-cli -D
npx @openapitools/openapi-generator-cli validate -i openapi.yaml
npx @openapitools/openapi-generator-cli generate \
  -i openapi.yaml \
  -g typescript-fetch \
  -o generated/client \
  --additional-properties=npmName=@my-org/api-client,npmVersion=0.1.0
```

Ajouter un script reproductible dans `package.json` si la generation devient un workflow regulier:

```json
{
  "scripts": {
    "generate:api-client": "openapi-generator-cli generate -i openapi.yaml -g typescript-fetch -o generated/client --additional-properties=npmName=@my-org/api-client,npmVersion=0.1.0"
  }
}
```

## Options

- `-i`: chemin vers la specification OpenAPI.
- `-g`: generateur cible, par exemple `typescript-fetch`, `typescript-axios`, `python`, `go`.
- `-o`: dossier de sortie.
- `--additional-properties`: options specifiques au generateur, separees par des virgules.
- `list`: afficher les generateurs disponibles.
- `config-help -g <generateur>`: afficher les options d'un generateur cible.
- `validate -i <spec>`: valider la specification avant generation.

Pour OpenAPI 3.1.x, utiliser OpenAPI Generator 7.x ou plus recent, et pinner une version recente en CI.

## References Et Resources

Charger `references/openapi-generator-cli.md` pour des snippets plus detailles, des exemples par langage, et les liens officiels.

References officielles utiles:

- OpenAPI Generator CLI Installation: https://openapi-generator.tech/docs/installation/
- OpenAPI Generator Usage: https://openapi-generator.tech/docs/usage/
- OpenAPI Generator Generators List: https://openapi-generator.tech/docs/generators/
- TypeScript Fetch generator options: https://openapi-generator.tech/docs/generators/typescript-fetch/

Ce skill n'a pas besoin de `scripts/` ni d'`assets/`: la generation est deleguee a OpenAPI Generator via Docker ou npm.
