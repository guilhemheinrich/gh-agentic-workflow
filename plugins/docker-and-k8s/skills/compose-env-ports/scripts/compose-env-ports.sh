#!/usr/bin/env bash
set -u

ROOT="."
COMPOSE_FILE=""
ENV_FILE=""
APPLY=0
START=1024
END=""
RESERVE=""
QUIET=0

TMP_FILES=""
VAR_NAMES=()
VAR_DEFAULTS=()
VAR_LINES=()
LITERAL_PORTS=()
LITERAL_LINES=()
SPLIT_FIELDS=()

usage() {
  cat <<'USAGE'
Usage: compose-env-ports.sh [options]

Detect .env-backed Docker Compose published host ports, compare them with local
Docker/listener usage, and propose deterministic free values.

Options:
  --root DIR          Project root to inspect (default: current directory)
  --compose FILE      Compose file path (default: compose.yml, compose.yaml,
                      docker-compose.yml, docker-compose.yaml)
  --env FILE          Env file path (default: .env under --root)
  --dry-run           Print proposed changes without writing (default)
  --apply             Update or create the env file
  --start PORT        First candidate port (default: 1024)
  --end PORT          Last candidate port (default: before OS ephemeral range)
  --reserve LIST      Extra reserved ports/ranges, e.g. 3000,5000-5010
  --quiet             Suppress warnings
  -h, --help          Show this help
USAGE
}

warn() {
  if [ "$QUIET" -eq 0 ]; then
    printf 'warning: %s\n' "$*" >&2
  fi
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

make_temp() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/compose-env-ports.XXXXXX") || exit 1
  TMP_FILES="${TMP_FILES} ${f}"
  printf '%s\n' "$f"
}

cleanup() {
  local f
  for f in $TMP_FILES; do
    rm -f "$f"
  done
}

trap cleanup EXIT INT TERM

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

strip_outer_quotes() {
  local v
  v=$(trim "$1")
  case "$v" in
    \"*\")
      v=${v#\"}
      v=${v%\"}
      ;;
    \'*\')
      v=${v#\'}
      v=${v%\'}
      ;;
  esac
  printf '%s\n' "$v"
}

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

valid_port() {
  is_uint "${1:-}" || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        [ "$#" -ge 2 ] || die "--root requires a value"
        ROOT=$2
        shift 2
        ;;
      --compose)
        [ "$#" -ge 2 ] || die "--compose requires a value"
        COMPOSE_FILE=$2
        shift 2
        ;;
      --env)
        [ "$#" -ge 2 ] || die "--env requires a value"
        ENV_FILE=$2
        shift 2
        ;;
      --dry-run)
        APPLY=0
        shift
        ;;
      --apply|--write)
        APPLY=1
        shift
        ;;
      --start)
        [ "$#" -ge 2 ] || die "--start requires a value"
        START=$2
        shift 2
        ;;
      --end)
        [ "$#" -ge 2 ] || die "--end requires a value"
        END=$2
        shift 2
        ;;
      --reserve)
        [ "$#" -ge 2 ] || die "--reserve requires a value"
        if [ -n "$RESERVE" ]; then
          RESERVE="${RESERVE},$2"
        else
          RESERVE=$2
        fi
        shift 2
        ;;
      --quiet)
        QUIET=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

absolutize_under_root() {
  case "$1" in
    /*)
      printf '%s\n' "$1"
      ;;
    *)
      printf '%s\n' "$ROOT/$1"
      ;;
  esac
}

find_compose_file() {
  local f
  for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    if [ -f "$ROOT/$f" ]; then
      printf '%s\n' "$ROOT/$f"
      return 0
    fi
  done
  return 1
}

detect_ephemeral_start() {
  if [ -r /proc/sys/net/ipv4/ip_local_port_range ]; then
    awk '{ print $1 }' /proc/sys/net/ipv4/ip_local_port_range
    return 0
  fi

  if have sysctl; then
    sysctl -n net.inet.ip.portrange.hifirst 2>/dev/null && return 0
  fi

  return 1
}

resolve_inputs() {
  [ -d "$ROOT" ] || die "root does not exist: $ROOT"

  if [ -n "$COMPOSE_FILE" ]; then
    COMPOSE_FILE=$(absolutize_under_root "$COMPOSE_FILE")
  else
    COMPOSE_FILE=$(find_compose_file) || die "no compose.yml, compose.yaml, docker-compose.yml, or docker-compose.yaml found under $ROOT"
  fi

  [ -f "$COMPOSE_FILE" ] || die "compose file does not exist: $COMPOSE_FILE"

  if [ -n "$ENV_FILE" ]; then
    ENV_FILE=$(absolutize_under_root "$ENV_FILE")
  else
    ENV_FILE="$ROOT/.env"
  fi

  is_uint "$START" || die "--start must be numeric"
  if [ -z "$END" ]; then
    local ephem
    ephem=$(detect_ephemeral_start || true)
    if is_uint "$ephem" && [ "$ephem" -gt "$START" ]; then
      END=$((ephem - 1))
    else
      END=49151
    fi
  fi

  is_uint "$END" || die "--end must be numeric"
  [ "$START" -ge 1024 ] || die "--start must be >= 1024"
  [ "$END" -ge "$START" ] || die "--end must be >= --start"
}

env_has_key() {
  local key=$1
  [ -f "$ENV_FILE" ] || return 1
  awk -v key="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      pos=index(line, "=")
      if (!pos) next
      k=substr(line, 1, pos - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$ENV_FILE"
}

env_value() {
  local key=$1
  [ -f "$ENV_FILE" ] || return 0
  awk -v key="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      pos=index(line, "=")
      if (!pos) next
      k=substr(line, 1, pos - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key) {
        v=substr(line, pos + 1)
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        value=v
        found=1
      }
    }
    END { if (found) print value }
  ' "$ENV_FILE"
}

set_env_value() {
  local key=$1
  local value=$2
  local tmp

  if [ ! -f "$ENV_FILE" ]; then
    : > "$ENV_FILE" || die "cannot create $ENV_FILE"
  fi

  tmp=$(make_temp)
  awk -v key="$key" -v value="$value" '
    BEGIN { done=0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    {
      original=$0
      line=$0
      sub(/\r$/, "", line)
      exported=0
      check=line
      if (check ~ /^[[:space:]]*export[[:space:]]+/) {
        exported=1
        sub(/^[[:space:]]*export[[:space:]]+/, "", check)
      }
      pos=index(check, "=")
      if (pos) {
        k=substr(check, 1, pos - 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (k == key) {
          if (exported) print "export " key "=" value
          else print key "=" value
          done=1
          next
        }
      }
      print original
    }
    END { if (!done) print key "=" value }
  ' "$ENV_FILE" > "$tmp" || die "cannot update $ENV_FILE"

  mv "$tmp" "$ENV_FILE" || die "cannot replace $ENV_FILE"
}

split_top_level_colons() {
  local s=$1
  local i=0
  local ch
  local two
  local cur=""
  local depth=0
  local bracket=0

  SPLIT_FIELDS=()
  while [ "$i" -lt "${#s}" ]; do
    ch=${s:$i:1}
    two=${s:$i:2}

    if [ "$two" = '${' ]; then
      depth=$((depth + 1))
      cur="${cur}\${"
      i=$((i + 2))
      continue
    fi

    if [ "$ch" = "}" ] && [ "$depth" -gt 0 ]; then
      depth=$((depth - 1))
    fi

    if [ "$ch" = "[" ] && [ "$depth" -eq 0 ]; then
      bracket=1
    elif [ "$ch" = "]" ] && [ "$depth" -eq 0 ]; then
      bracket=0
    fi

    if [ "$ch" = ":" ] && [ "$depth" -eq 0 ] && [ "$bracket" -eq 0 ]; then
      SPLIT_FIELDS[${#SPLIT_FIELDS[@]}]=$cur
      cur=""
    else
      cur="${cur}${ch}"
    fi

    i=$((i + 1))
  done

  SPLIT_FIELDS[${#SPLIT_FIELDS[@]}]=$cur
}

host_field_from_short_syntax() {
  local line=$1
  local value
  local count

  value=${line#*-}
  value=$(trim "$value")
  value=${value%%#*}
  value=$(strip_outer_quotes "$value")

  case "$value" in
    target:*|published:*|protocol:*|mode:*|name:*|app_protocol:*)
      return 1
      ;;
  esac

  split_top_level_colons "$value"
  count=${#SPLIT_FIELDS[@]}
  [ "$count" -ge 2 ] || return 1

  if [ "$count" -eq 2 ]; then
    trim "${SPLIT_FIELDS[0]}"
  else
    trim "${SPLIT_FIELDS[$((count - 2))]}"
  fi
}

is_port_candidate() {
  local var=$1
  local default=$2

  if valid_port "$default"; then
    return 0
  fi

  case "$var" in
    *PORT*|*Port*|*port*)
      return 0
      ;;
  esac

  return 1
}

add_var_record() {
  local var=$1
  local default=$2
  local line_no=$3
  local i

  case "$var" in
    ''|*[!A-Za-z0-9_]*)
      return 0
      ;;
  esac

  if ! valid_port "$default"; then
    default=""
  fi

  is_port_candidate "$var" "$default" || return 0

  for i in "${!VAR_NAMES[@]}"; do
    if [ "${VAR_NAMES[$i]}" = "$var" ]; then
      if [ -z "${VAR_DEFAULTS[$i]}" ] && [ -n "$default" ]; then
        VAR_DEFAULTS[$i]=$default
      fi
      VAR_LINES[$i]="${VAR_LINES[$i]},$line_no"
      return 0
    fi
  done

  VAR_NAMES[${#VAR_NAMES[@]}]=$var
  VAR_DEFAULTS[${#VAR_DEFAULTS[@]}]=$default
  VAR_LINES[${#VAR_LINES[@]}]=$line_no
}

add_literal_port() {
  local port=$1
  local line_no=$2
  local i

  valid_port "$port" || return 0
  for i in "${!LITERAL_PORTS[@]}"; do
    if [ "${LITERAL_PORTS[$i]}" = "$port" ]; then
      LITERAL_LINES[$i]="${LITERAL_LINES[$i]},$line_no"
      return 0
    fi
  done

  LITERAL_PORTS[${#LITERAL_PORTS[@]}]=$port
  LITERAL_LINES[${#LITERAL_LINES[@]}]=$line_no
}

extract_vars_from_host_field() {
  local text=$1
  local line_no=$2
  local rest=$text
  local match
  local prefix
  local var
  local default

  while [[ "$rest" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:?-([^}]*))?\} ]]; do
    match=${BASH_REMATCH[0]}
    var=${BASH_REMATCH[1]}
    default=$(strip_outer_quotes "${BASH_REMATCH[3]-}")
    add_var_record "$var" "$default" "$line_no"
    prefix=${rest%%"$match"*}
    rest=${rest:$(( ${#prefix} + ${#match} ))}
  done
}

scan_compose_ports() {
  local port_lines
  local rec
  local line_no
  local line
  local value
  local host_field

  port_lines=$(make_temp)
  awk '
    function leading_spaces(s, t) {
      t=s
      gsub(/\t/, "  ", t)
      sub(/[^ ].*$/, "", t)
      return length(t)
    }
    {
      raw=$0
      gsub(/\t/, "  ", raw)
      if (in_ports) {
        if (raw ~ /^[[:space:]]*($|#)/) next
        ind=leading_spaces(raw)
        if (ind <= pindent && raw !~ /^[[:space:]]*-/) in_ports=0
      }
      if (!in_ports && raw ~ /^[[:space:]]+ports:[[:space:]]*($|#)/) {
        in_ports=1
        pindent=leading_spaces(raw)
        next
      }
      if (in_ports) print NR ":" raw
    }
  ' "$COMPOSE_FILE" > "$port_lines"

  while IFS= read -r rec; do
    line_no=${rec%%:*}
    line=${rec#*:}

    case "$line" in
      *published:*)
        value=${line#*published:}
        value=${value%%#*}
        host_field=$(strip_outer_quotes "$value")
        extract_vars_from_host_field "$host_field" "$line_no"
        if valid_port "$host_field"; then
          add_literal_port "$host_field" "$line_no"
        fi
        ;;
      *)
        host_field=$(host_field_from_short_syntax "$line") || continue
        extract_vars_from_host_field "$host_field" "$line_no"
        if valid_port "$host_field"; then
          add_literal_port "$host_field" "$line_no"
        fi
        ;;
    esac
  done < "$port_lines"
}

sort_port_file() {
  local file=$1
  local sorted

  sorted=$(make_temp)
  awk '($0 ~ /^[0-9]+$/) && ($0 >= 1) && ($0 <= 65535) { print $0 }' "$file" \
    | sort -n -u > "$sorted"
  mv "$sorted" "$file"
}

collect_used_ports() {
  local used_file=$1
  local docker_file=$2
  local listener_file=$3

  : > "$used_file"
  : > "$docker_file"
  : > "$listener_file"

  if have docker; then
    if docker info >/dev/null 2>&1; then
      docker ps --format '{{.Ports}}' 2>/dev/null \
        | grep -Eo ':[0-9]+->' \
        | sed 's/[^0-9]//g' >> "$docker_file" || true
    else
      warn "Docker is installed but the daemon is not reachable; skipping Docker published-port inventory"
    fi
  else
    warn "docker command not found; skipping Docker published-port inventory"
  fi

  if have lsof; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
      | awk 'NR > 1 { v=$9; sub(/.*:/, "", v); sub(/[^0-9].*$/, "", v); if (v ~ /^[0-9]+$/) print v }' >> "$listener_file" || true
  elif have ss; then
    ss -H -ltn 2>/dev/null \
      | awk '{ v=$4; sub(/.*:/, "", v); sub(/[^0-9].*$/, "", v); if (v ~ /^[0-9]+$/) print v }' >> "$listener_file" || true
  elif have netstat; then
    netstat -an 2>/dev/null \
      | awk '/LISTEN/ { v=$4; sub(/.*[.:]/, "", v); if (v ~ /^[0-9]+$/) print v }' >> "$listener_file" || true
  else
    warn "no listener inventory tool found (lsof, ss, netstat); relying only on candidate bookkeeping"
  fi

  sort_port_file "$docker_file"
  sort_port_file "$listener_file"
  cat "$docker_file" "$listener_file" > "$used_file"
  sort_port_file "$used_file"
}

port_list() {
  local file=$1

  awk '
    BEGIN { first=1 }
    {
      if (!first) printf ","
      printf "%s", $0
      first=0
    }
    END {
      if (first) printf "-"
    }
  ' "$file"
}

port_in_file() {
  local port=$1
  local file=$2
  grep -qx "$port" "$file" 2>/dev/null
}

is_extra_reserved() {
  local port=$1
  local list
  local item
  local from
  local to

  list=$(printf '%s' "$RESERVE" | tr ',' ' ')
  for item in $list; do
    case "$item" in
      *-*)
        from=${item%-*}
        to=${item#*-}
        if is_uint "$from" && is_uint "$to" && [ "$port" -ge "$from" ] && [ "$port" -le "$to" ]; then
          return 0
        fi
        ;;
      *)
        if is_uint "$item" && [ "$port" -eq "$item" ]; then
          return 0
        fi
        ;;
    esac
  done

  return 1
}

is_allowed_port() {
  local port=$1

  valid_port "$port" || return 1
  [ "$port" -ge "$START" ] || return 1
  [ "$port" -le "$END" ] || return 1
  is_extra_reserved "$port" && return 1
  return 0
}

port_is_taken() {
  local port=$1
  local used_file=$2

  port_in_file "$port" "$used_file" && return 0

  if have nc; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && return 0
  fi

  return 1
}

find_free_port() {
  local preferred=$1
  local used_file=$2
  local proposed_file=$3
  local port

  if is_allowed_port "$preferred" \
    && ! port_is_taken "$preferred" "$used_file" \
    && ! port_in_file "$preferred" "$proposed_file"; then
    printf '%s\n' "$preferred"
    return 0
  fi

  if is_uint "$preferred" && [ "$preferred" -ge "$START" ] && [ "$preferred" -lt "$END" ]; then
    port=$((preferred + 1))
  else
    port=$START
  fi

  while [ "$port" -le "$END" ]; do
    if is_allowed_port "$port" \
      && ! port_is_taken "$port" "$used_file" \
      && ! port_in_file "$port" "$proposed_file"; then
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
  done

  return 1
}

reason_for_port() {
  local has_env=$1
  local env_current=$2
  local base=$3
  local used_file=$4
  local proposed_file=$5

  if [ "$has_env" -eq 1 ] && ! valid_port "$env_current"; then
    printf 'invalid-env\n'
  elif [ -z "$base" ]; then
    printf 'missing\n'
  elif ! is_allowed_port "$base"; then
    printf 'reserved\n'
  elif port_is_taken "$base" "$used_file"; then
    printf 'occupied\n'
  elif port_in_file "$base" "$proposed_file"; then
    printf 'duplicate\n'
  elif [ "$has_env" -eq 0 ]; then
    printf 'add\n'
  else
    printf 'ok\n'
  fi
}

print_literal_report() {
  local i

  if [ "${#LITERAL_PORTS[@]}" -eq 0 ]; then
    return 0
  fi

  printf '\nLiteral published host ports detected; convert these to ${VAR:-default} if they should be managed through .env:\n'
  for i in "${!LITERAL_PORTS[@]}"; do
    printf '  port %-6s compose line(s): %s\n' "${LITERAL_PORTS[$i]}" "${LITERAL_LINES[$i]}"
  done
}

main() {
  local used_file
  local docker_file
  local listener_file
  local proposed_file
  local i
  local var
  local default
  local raw
  local env_current
  local has_env
  local base
  local candidate
  local reason
  local writes=0
  local changed=0
  local current_display
  local default_display

  parse_args "$@"
  resolve_inputs
  scan_compose_ports

  used_file=$(make_temp)
  docker_file=$(make_temp)
  listener_file=$(make_temp)
  proposed_file=$(make_temp)
  : > "$proposed_file"
  collect_used_ports "$used_file" "$docker_file" "$listener_file"

  printf 'Compose file: %s\n' "$COMPOSE_FILE"
  printf 'Env file:     %s\n' "$ENV_FILE"
  printf 'Port range:   %s-%s\n' "$START" "$END"
  printf 'Docker ports: %s\n' "$(port_list "$docker_file")"
  printf 'Listener ports: %s\n' "$(port_list "$listener_file")"
  if [ -n "$RESERVE" ]; then
    printf 'Extra reserve: %s\n' "$RESERVE"
  fi

  if [ "${#VAR_NAMES[@]}" -eq 0 ]; then
    printf '\nNo .env-backed published host port variables were found in compose ports.\n'
    print_literal_report
    exit 0
  fi

  printf '\n%-30s %-10s %-10s %-10s %-12s %s\n' "VARIABLE" "CURRENT" "DEFAULT" "PROPOSED" "ACTION" "COMPOSE_LINES"
  printf '%-30s %-10s %-10s %-10s %-12s %s\n' "--------" "-------" "-------" "--------" "------" "-------------"

  for i in "${!VAR_NAMES[@]}"; do
    var=${VAR_NAMES[$i]}
    default=${VAR_DEFAULTS[$i]}
    raw=$(env_value "$var")
    env_current=$(strip_outer_quotes "$raw")
    has_env=0
    if env_has_key "$var"; then
      has_env=1
    fi

    if [ "$has_env" -eq 1 ] && valid_port "$env_current"; then
      base=$env_current
    elif valid_port "$default"; then
      base=$default
    else
      base=""
    fi

    candidate=$(find_free_port "$base" "$used_file" "$proposed_file") || die "no free port found for $var in range $START-$END"
    reason=$(reason_for_port "$has_env" "$env_current" "$base" "$used_file" "$proposed_file")
    printf '%s\n' "$candidate" >> "$proposed_file"

    current_display=$env_current
    default_display=$default
    [ -n "$current_display" ] || current_display="-"
    [ -n "$default_display" ] || default_display="-"

    printf '%-30s %-10s %-10s %-10s %-12s %s\n' "$var" "$current_display" "$default_display" "$candidate" "$reason" "${VAR_LINES[$i]}"

    if [ "$reason" != "ok" ] || [ "$env_current" != "$candidate" ]; then
      changed=$((changed + 1))
      if [ "$APPLY" -eq 1 ]; then
        set_env_value "$var" "$candidate"
        writes=$((writes + 1))
      fi
    fi
  done

  print_literal_report

  if [ "$APPLY" -eq 1 ]; then
    printf '\nApplied %s .env assignment(s).\n' "$writes"
  else
    printf '\nDry run only. %s assignment(s) would be added or changed. Re-run with --apply to update .env.\n' "$changed"
  fi
}

main "$@"
