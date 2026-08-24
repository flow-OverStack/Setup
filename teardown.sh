#!/usr/bin/env bash
# Reverses setup.sh. By default: stops and removes containers/networks only -
# named volumes (your databases, Keycloak realm, Kafka log) are kept, so the
# next setup.sh comes back up in well under a minute with all data intact.
#
# --volumes  also wipes Postgres/Redis/Keycloak/Kafka/Elasticsearch data and
#            clears KC_ADMIN_TOKEN from .env (all-or-nothing: Kafka's CLUSTER_ID
#            is pinned in the common compose, so wiping kafka_data alone leaves
#            it inconsistent; clearing the secret keeps the realm import in step
#            with the next fresh Keycloak DB).
# --images   also removes the pulled/built Docker images.
# --all      --volumes --images, plus .keycloak-import/ and logs/.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
if command -v cygpath >/dev/null 2>&1; then
  SETUP_ROOT="$(cygpath -m "$(pwd)")"
else
  SETUP_ROOT="$(pwd)"
fi
export SETUP_ROOT

# shellcheck source=lib/log.sh
source lib/log.sh
mkdir -p logs
LOG_FILE="logs/teardown-$(date '+%Y%m%d-%H%M%S').log"
export LOG_FILE
export VERBOSE=0

WIPE_VOLUMES=0
WIPE_IMAGES=0
WIPE_ALL=0
for arg in "$@"; do
  case "$arg" in
    --volumes) WIPE_VOLUMES=1 ;;
    --images) WIPE_IMAGES=1 ;;
    --all) WIPE_VOLUMES=1; WIPE_IMAGES=1; WIPE_ALL=1 ;;
    --verbose) VERBOSE=1 ;;
    *) log_fail "Unknown flag: $arg"; exit 1 ;;
  esac
done

[ -f .env ] && { set -a; source .env; set +a; }

COMPOSE="docker compose --env-file .env"

down() {
  local project="$1"; shift
  log_step "Stopping $project"
  # `down` is not fatal if the project was never started.
  $COMPOSE -p "$project" "$@" down --remove-orphans 2>&1 | tee -a "$LOG_FILE" || true
}

if [ -d repos/ApolloGateway ]; then
  log_step "Stopping Apollo Gateway"
  (cd repos/ApolloGateway && docker compose down --remove-orphans 2>&1 | tee -a "$SETUP_ROOT/$LOG_FILE") || true
fi

[ -d repos/NotificationService ] && down notificationservice -f repos/NotificationService/docker-compose.yaml
[ -d repos/AnswerService ] && down answerservice -f repos/AnswerService/docker-compose.yaml
[ -d repos/QuestionService ] && down questionservice -f repos/QuestionService/docker-compose.yml
[ -d repos/UserService ] && down userservice -f repos/UserService/docker-compose.yml

if [ -d repos/UserService ]; then
  log_step "Stopping common infrastructure"
  $COMPOSE -p flowoverstack -f repos/UserService/docker-compose.common.yml -f overrides/common.override.yml \
    down --remove-orphans 2>&1 | tee -a "$LOG_FILE" || true
fi

if [ "$WIPE_VOLUMES" = "1" ]; then
  log_step "Removing named volumes"
  # Compose prefixes each volume with its project's -p name:
  #   userservice_{postgres_data,redis_data}, questionservice_{...}, answerservice_{...},
  #   notificationservice_{...}, flowoverstack_{keycloak_data,keycloak_db_data,
  #   kafka_data,kafka_schema_data,elasticsearch_data}.
  docker volume ls -q | grep -E '^(userservice|questionservice|answerservice|notificationservice|flowoverstack)_' \
    | xargs -r docker volume rm >>"$LOG_FILE" 2>&1 || true

  if [ -f .env ] && grep -q '^KC_ADMIN_TOKEN=' .env; then
    sed -i 's/^KC_ADMIN_TOKEN=.*/KC_ADMIN_TOKEN=/' .env
    log_step "Cleared KC_ADMIN_TOKEN from .env (will regenerate on next setup.sh)"
  fi
  rm -f .setup-complete
  log_ok "Volumes removed"
fi

if [ "$WIPE_IMAGES" = "1" ]; then
  log_step "Removing Docker images"
  docker image ls --format '{{.Repository}}:{{.Tag}}' \
    | grep -E 'maratkk/flow-overstack_|apollogateway' \
    | xargs -r docker rmi >>"$LOG_FILE" 2>&1 || true
  log_ok "Images removed"
fi

if [ "$WIPE_ALL" = "1" ]; then
  log_step "Removing .keycloak-import/ and logs/"
  rm -rf .keycloak-import
  # Keep the log we're currently writing to.
  find logs -type f ! -name "$(basename "$LOG_FILE")" -delete
fi

log_ok "Teardown complete"
