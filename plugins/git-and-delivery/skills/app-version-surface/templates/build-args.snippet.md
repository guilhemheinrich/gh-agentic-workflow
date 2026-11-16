# Build-time injection snippets

Values come from the build, never from guessing at runtime.

## Dockerfile

```dockerfile
ARG APP_VERSION
ARG GIT_COMMIT
ARG BUILD_TIME
ARG APP_ENV=production
ENV APP_VERSION=$APP_VERSION GIT_COMMIT=$GIT_COMMIT BUILD_TIME=$BUILD_TIME APP_ENV=$APP_ENV
```

```bash
docker build \
  --build-arg APP_VERSION="$(node -p "require('./package.json').version")" \
  --build-arg GIT_COMMIT="$(git rev-parse --short=7 HEAD)" \
  --build-arg BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" .
```

## Vite (static frontend)

```bash
VITE_APP_VERSION=$(node -p "require('./package.json').version") \
VITE_GIT_COMMIT=$(git rev-parse --short=7 HEAD) \
VITE_BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
VITE_APP_ENV=production npm run build
```

Then compute the display string:

```ts
const displayVersion = `${import.meta.env.VITE_APP_VERSION}+${import.meta.env.VITE_GIT_COMMIT}`;
```

## Backend endpoint (any stack)

Serve `GET /version` with a payload validating against `version.schema.json`,
built from the `APP_VERSION`, `GIT_COMMIT`, `BUILD_TIME` and `APP_ENV` variables.
