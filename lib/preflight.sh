#!/usr/bin/env bash
# Sourced by setup.sh. Fails fast on missing prerequisites instead of letting
# a 6-minute compose run die halfway through with a cryptic error.

MIN_RAM_GB=8

preflight() {
  log_step "Preflight checks"

  command -v docker >/dev/null || { log_fail "docker not found on PATH"; exit 1; }
  command -v node >/dev/null || { log_fail "node not found on PATH"; exit 1; }
  command -v git >/dev/null || { log_fail "git not found on PATH"; exit 1; }

  if ! docker compose version >/dev/null 2>&1; then
    log_fail "docker compose v2 not found (the 'docker-compose' v1 binary is not supported)"
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    log_fail "Docker daemon is not running"
    exit 1
  fi

  local ram_bytes ram_gb
  ram_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  ram_gb=$((ram_bytes / 1024 / 1024 / 1024))
  if [ "$ram_gb" -gt 0 ] && [ "$ram_gb" -lt "$MIN_RAM_GB" ]; then
    log_warn "Docker has ${ram_gb}GB RAM available, ${MIN_RAM_GB}GB+ recommended."
    log_warn "Elasticsearch and Kafka are prone to OOM-kills below that - consider --lite."
  fi

  local ports=(8080 8081 8888 9092 9101 16686 4317 4318 9090 3000 9200 5601 18888 18889
               8085 8086 5433 5046 8000 6379 8087 8088 5435 5047 8001 6380
               8089 8090 5436 5048 8002 6381 8091 5437 5049 8003 6382 5000)
  # Snapshot the listening sockets once, then grep it per port. `ss` is absent on
  # Git Bash - the primary Windows path - so fall back to Windows netstat, whose
  # rows look like "  TCP    0.0.0.0:8080    0.0.0.0:0    LISTENING    1704".
  local listening=""
  if command -v ss >/dev/null 2>&1; then
    listening=$(ss -ltn 2>/dev/null)
  elif command -v netstat >/dev/null 2>&1; then
    listening=$(netstat -ano 2>/dev/null | grep -i 'LISTEN')
  fi

  local busy=()
  if [ -n "$listening" ]; then
    for p in "${ports[@]}"; do
      grep -qE "[:.]$p[[:space:]]" <<<"$listening" && busy+=("$p")
    done
  fi
  if [ "${#busy[@]}" -gt 0 ]; then
    log_warn "Ports already in use on the host: ${busy[*]}"
    log_warn "flow OverStack will fail to bind these unless whatever's using them is stopped."
  fi

  log_ok "Preflight checks passed"
}
