@echo off
docker compose -f "%~dp0compose.yml" exec -T lw python3 /opt/watchers/linear-atlas/scripts/lw %*
