#!/usr/bin/env bash
# Manages the heavy Kafka-ecosystem services that setup.sh defers via the
# `extras` compose profile (see overrides/common.override.yml): control-center,
# connect, rest-proxy, schema-registry, flink-jobmanager, flink-taskmanager,
# flink-sql-client. Not needed for the app to work - useful for inspecting Kafka.
#
# Usage:
#   ./extras.sh create        # create all extras, don't start them
#   ./extras.sh up            # start all extras
#   ./extras.sh up <name>     # start one, e.g. ./extras.sh up control-center
#   ./extras.sh down          # stop all extras
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
[ -f .env ] && { set -a; source .env; set +a; }

COMPOSE="docker compose --env-file .env -p flowoverstack \
  -f repos/UserService/docker-compose.common.yml -f overrides/common.override.yml --profile extras"

cmd="${1:-}"
shift || true

case "$cmd" in
  create) $COMPOSE create "$@" ;;
  up) $COMPOSE up -d "$@" ;;
  down) $COMPOSE down "$@" ;;
  *)
    echo "Usage: $0 {create|up|down} [service-name]" >&2
    exit 1
    ;;
esac
