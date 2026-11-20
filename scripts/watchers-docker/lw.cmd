@echo off
docker compose -f "%~dp0compose.yml" exec -T lw python3 /opt/watchers/linear-tracker/scripts/lw %*
