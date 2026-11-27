@echo off
set "TARGET=/opt/watchers/linear-atlas/scripts/lw"
docker compose -f "%~dp0compose.yml" exec -T lw test -f %TARGET%
if errorlevel 1 (
  echo lw: %TARGET% is missing in the watchers container: it is not running, or its image is stale. Rebuild: docker compose -f "%~dp0compose.yml" up -d --build 1>&2
  exit /b 127
)
docker compose -f "%~dp0compose.yml" exec -T lw python3 %TARGET% %*
