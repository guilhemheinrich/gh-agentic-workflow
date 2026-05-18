#!/bin/sh
set -eu

missing=""

for var in SONAR_HOST_URL SONAR_TOKEN SONAR_PROJECT_KEY; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    missing="$missing $var"
  fi
done

if [ -n "$missing" ]; then
  echo "Missing required environment variables:$missing" >&2
  echo "Define them in .env and pass them with: docker run --env-file .env ..." >&2
  exit 2
fi

exec sonar-scanner \
  -Dsonar.host.url="$SONAR_HOST_URL" \
  -Dsonar.token="$SONAR_TOKEN" \
  -Dsonar.projectKey="$SONAR_PROJECT_KEY" \
  "$@"
