#!/usr/bin/env bash
# Sourced by setup.sh. depends_on doesn't wait for readiness and none of the
# base compose files carry healthchecks, so every gate here is an explicit
# poll - never a fixed sleep.

# wait_http <url> <timeout_seconds> [expected_status]
# Polls until the URL returns the expected HTTP status (default: any 2xx-4xx,
# i.e. "the server answered at all" - used for endpoints that are up but
# return 404/401 by design before the app is fully warm).
wait_http() {
  local url="$1" timeout="${2:-120}" want="${3:-}"
  local start
  start=$(date +%s)
  while true; do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo 000)
    if [ -n "$want" ]; then
      [ "$code" = "$want" ] && return 0
    else
      [[ "$code" =~ ^[2-4][0-9][0-9]$ ]] && return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log_fail "Timed out after ${timeout}s waiting for $url (last status: $code)"
      return 1
    fi
    sleep 2
  done
}

# wait_health <url> <timeout_seconds>
# Polls a .NET /health endpoint until the body is exactly "Healthy".
wait_health() {
  local url="$1" timeout="${2:-180}"
  local start
  start=$(date +%s)
  while true; do
    local body
    body=$(curl -s --max-time 5 "$url" 2>/dev/null || true)
    [ "$body" = "Healthy" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log_fail "Timed out after ${timeout}s waiting for $url to report Healthy (last: ${body:0:200})"
      return 1
    fi
    sleep 3
  done
}

# wait_container_running <container_name> <timeout_seconds>
wait_container_running() {
  local name="$1" timeout="${2:-60}"
  local start
  start=$(date +%s)
  while true; do
    local state
    state=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)
    [ "$state" = "true" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log_fail "Container $name did not reach running state within ${timeout}s"
      return 1
    fi
    sleep 2
  done
}

# on_wait_fail <container_name>
# Prints the last 30 lines of a container's logs - called by setup.sh right
# after any wait_* call fails, so the failure is diagnosable without digging.
on_wait_fail() {
  local name="$1"
  log_fail "--- last 30 lines of '$name' logs ---"
  docker logs --tail 30 "$name" 2>&1 | tee -a "$LOG_FILE" >&2 || true
  log_fail "--- see $LOG_FILE for the full run ---"
}
