@echo off
docker compose -f "%~dp0compose.yml" exec -T prw bash /opt/watchers/pr-watch/scripts/prw %*
