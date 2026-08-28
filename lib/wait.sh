#!/usr/bin/env bash
# Sourced by setup.sh. overrides/deps adds a healthcheck to each service's
# Postgres (and gates the service on it), but nothing else in the stack carries
# one - so every gate here is an explicit poll, never a fixed sleep.

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
# Polls a .NET /health endpoint until its top-level status is "Healthy". The
# four services all map /health with HealthCheckOptions { ResponseWriter =
# UIResponseWriter.WriteHealthCheckUIResponse } (see Program.cs), which returns
# a JSON body like {"status":"Healthy","entries":{...}} - NOT a bare "Healthy"
# string - so this has to parse it, not string-compare the raw body.
wait_health() {
  local url="$1" timeout="${2:-180}"
  local start
  start=$(date +%s)
  while true; do
    local body status
    body=$(curl -s --max-time 5 "$url" 2>/dev/null || true)
    status=$(printf '%s' "$body" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{process.stdout.write(JSON.parse(d).status||'')}catch{}})" 2>/dev/null)
    [ "$status" = "Healthy" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log_fail "Timed out after ${timeout}s waiting for $url to report Healthy (last status: ${status:-<unparseable>}, body: ${body:0:200})"
      return 1
    fi
    sleep 3
  done
}

# wait_container_running <container_name> <timeout_seconds>
# NOTE: this only proves the container's process has started - for cp-server's
# Kafka broker specifically, that happens within seconds, long before the broker
# has finished KRaft storage formatting and log recovery and can actually serve
# requests. Use wait_kafka_broker for the broker; this is for containers where
# "process is running" is an adequate proxy for "ready".
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

# wait_kafka_broker <container_name> <timeout_seconds>
# Kafka cold starts can genuinely take up to ~5 minutes (KRaft storage format,
# log recovery) even though the container process itself is "Running" within
# seconds - wait_container_running would pass almost immediately and let
# setup.sh race ahead to start the four app services against a broker that
# isn't actually serving yet. kafka-broker-api-versions (ships in the
# confluentinc/cp-server image) only succeeds once the broker genuinely answers
# requests, so it's the real readiness probe, not a process-alive proxy.
wait_kafka_broker() {
  local name="$1" timeout="${2:-360}"
  local start
  start=$(date +%s)
  while true; do
    if docker exec "$name" kafka-broker-api-versions --bootstrap-server localhost:9092 >/dev/null 2>&1; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log_fail "Timed out after ${timeout}s waiting for the Kafka broker ($name) to answer kafka-broker-api-versions"
      return 1
    fi
    sleep 5
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
