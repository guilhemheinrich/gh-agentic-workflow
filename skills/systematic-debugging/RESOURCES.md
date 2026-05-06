# Docker Debugging Command Reference

## Container Status & Inspection

```bash
# List all containers (running, stopped, all)
docker ps                          # Running only
docker ps -a                       # All containers
docker ps -q                       # IDs only

# Container-specific info
docker inspect <container_id>      # Full JSON inspection
docker inspect --format='{{json .State}}' <container_id>
docker inspect --format='{{.State.Health}}' <container_id>

# Container status details
docker inspect --format='{{.State.Status}}' <container_id>
docker inspect --format='{{.NetworkSettings.IPAddress}}' <container_id>

# Container logs
docker logs <container>            # Tail logs
docker logs -f <container>         # Follow
docker logs --tail 100 <container> # Last 100 lines
docker logs --since 5m <container> # Since 5 minutes
docker logs --timestamps <container>

# Container stats & top processes
docker stats <container>           # Real-time stats
docker stats <container> -p        # As one-shot

# Execute commands inside container
docker exec -it <container> /bin/sh    # Interactive shell
docker exec <container> ps -ef         # List processes
docker exec <container> top -b -n 1    # Top processes

# Container info
docker inspect -f '{{.Name}}' <container>
docker inspect -f '{{.Config.Labels}}' <container>
docker port <container>               # List port mappings

# Container logs with colors
docker logs --color <container>
docker logs --tail -1000 --timestamps <container>

# Container exec with timeout & network
docker exec --timeout 30 <container> curl -v http://target:80

# Docker network inspection
docker network inspect <network_name>
docker network ls                     # List all networks
docker network inspect bridge         # Inspect specific network

# Docker storage inspect
docker system df                    # Disk usage
docker system df -v                 # Detailed disk usage
docker system prune                 # Remove unused data
```

## Network Debugging

```bash
# List all port mappings
docker port <container>

# Check network connectivity between containers
docker exec <container> curl -v http://other-service:port
docker exec <container> ping other-service
docker exec <container> nslookup other-service
docker exec <container> cat /etc/hosts

# Network troubleshooting tools
docker exec <container> apt-get install -y iputils-ping
docker exec <container> apt-get install -y net-tools
docker exec <container> apt-get install -y dnsutils

# View network connections
docker exec <container> ss -tulpn          # Linux
docker exec <container> netstat -tulpn     # Linux
docker exec <container> lsof -i :8080      # Processes using port

# TCP/HTTP requests
docker exec <container> curl -I http://service:port/head
docker exec <container> curl -v -X POST -d '{"key":"value"}' http://service:port/api
docker exec <container> wget --spider http://service:port

# Network inspection
docker network ls
docker network inspect bridge
docker network inspect -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' bridge
```

## Image & Volume Management

```bash
# List images
docker images
docker images -a                          # All including dangling
docker images --digests
docker images --filter "dangling=true"    # Free up space

# Image inspection
docker inspect <image_id>
docker history <image>

# Volume operations
docker volume ls                          # List volumes
docker volume inspect <volume_name>
docker volume create my-volume
docker volume remove <volume_name>

# Remove all stopped containers
docker container prune

# Remove all unused images
docker image prune
docker image prune -a             # All unused images
docker image prune --filter "until=24h"

# System cleanup
docker system prune -a -v --filter "until=24h"
```

## Docker Compose Specific Commands

```bash
# Compose status
docker-compose ps
docker-compose ps -a              # All services

# Service logs
docker-compose logs               # All services
docker-compose logs <service>     # Specific service
docker-compose logs --follow
docker-compose logs --tail 200
docker-compose logs --since 1h
docker-compose logs -f --tail 50

# Service inspection
docker-compose config             # Validate and view compose file
docker-compose config --services  # List services

# Service operations
docker-compose up -d              # Detached mode
docker-compose down               # Stop and remove
docker-compose restart <service>  # Restart service
docker-compose stop               # Stop all services
docker-compose stop <service>

# Resource inspection
docker-compose top <service>      # Show processes
docker-compose run --rm <service> <command> # Run one-off command

# Service logs with timestamps
docker-compose logs -f --timestamps
docker-compose logs -f --since 2024-01-01

# Health check specific
docker-compose ps --filter "status=starting"
docker-compose ps --filter "status=exited"
```

## Health Check & Status

```bash
# Check service health programmatically
docker inspect -f '{{.State.Health.Status}}' <container>
docker inspect -f '{{.State.Running}}' <container>
docker inspect -f '{{.State.ExitCode}}' <container>

# Container health details
docker inspect -f '{{.State.Health.Log}}' <container>

# Port mapping inspection
docker inspect -f '{{range .NetworkSettings.Ports}}{{index . 0}.HostPort}}{{end}}' <container>

# Network connectivity test
docker exec <container> wget -q --spider http://target:port && echo "OK" || echo "FAIL"

# Container uptime
docker inspect -f '{{.State.StartedAt}}' <container>
```

## Debug-Specific Commands

```bash
# Inspect container environment
docker exec <container> env
docker exec <container> env | grep PATTERN

# View mounted volumes and paths
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' <container>

# Inspect container user
docker inspect -f '{{.Config.User}}' <container>

# Container labels and metadata
docker inspect -f '{{range $k, $v := .Config.Labels}}{{$k}}: {{$v}}{{"\n"}}{{end}}' <container>

# Process tree inside container
docker exec <container> ps -ef --forest

# Debug container filesystem
docker exec -it <container> ls -la /path/to/check
docker exec -it <container> ls -laR /path/to/check | head -50

# Monitor container CPU/memory
watch -n1 'docker stats --no-stream <container>'

# Stream logs continuously
docker logs -f --timestamps <container> 2>&1 | tee debug.log

# Get container IP address
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' <container>

# List all containers with network info
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

## Useful One-Liners for Debugging

```bash
# Find all containers for a specific image
docker ps -a --filter "image=<image_name>"

# Find container by port
docker ps --filter "published-port=8080"

# Get container PID namespace
docker inspect -f '{{.HostConfig.PidMode}}' <container>

# List all containers with their network names
docker inspect --format '{{range $n, $v := .NetworkingData.Networks}}{{.Name}}{{"\n"}}{{end}}' <container_id>

# Check if container is healthy
docker inspect -f '{{if eq .State.Health.Status "healthy"}}YES{{else}}NO{{end}}' <container>

# Dump container resources usage summary
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Find broken containers by health
docker ps -a --filter "status=unhealthy"

# Get container exit details
docker inspect -f '{{.State.ExitCode}}{{"\n"}}{{.State.Error}}' <container>

# Inspect container command history
docker inspect -f '{{.Config.Entrypoint}} {{.Config.Cmd}}' <container>

# Check container resource limits
docker inspect -f '{{.HostConfig.Memory}}{{"\n"}}{{.HostConfig.CpuShares}}' <container>
```

## Troubleshooting Checklist

```bash
# 1. Check container status
docker ps -a | grep <container_name>

# 2. Inspect recent logs
docker logs --tail 100 --timestamps <container>

# 3. Verify network connectivity
docker exec <container> ping <target_service>

# 4. Check port accessibility
docker exec <container> curl -v http://<service>:<port>

# 5. Inspect environment variables
docker exec <container> env | grep <pattern>

# 6. Check mounted volumes
docker inspect -f '{{range .Mounts}}{{.Source}}{{" -> "}}{{.Destination}}{{"\n"}}{{end}}' <container>

# 7. View resource usage
docker stats <container> --no-stream

# 8. Inspect health status
docker inspect -f '{{.State.Health.Status}}' <container>

# 9. Restart container
docker restart <container>

# 10. Inspect container labels
docker inspect -f '{{range $k,$v:=.Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' <container>
```
