#!/usr/bin/env bash
# One-command bring-up for flow OverStack. See README.md for the full flag list.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# On Git Bash, docker (a native Windows binary) needs a Windows-style path for
# bind mounts - a plain `pwd` POSIX path (/c/Users/...) is unreliable for that.
# cygpath -m gives "C:/Users/..." which Docker Desktop always accepts.
if command -v cygpath >/dev/null 2>&1; then
  SETUP_ROOT="$(cygpath -m "$(pwd)")"
else
  SETUP_ROOT="$(pwd)"
fi
export SETUP_ROOT

# shellcheck source=lib/log.sh
source lib/log.sh
# shellcheck source=lib/preflight.sh
source lib/preflight.sh
# shellcheck source=lib/wait.sh
source lib/wait.sh
# shellcheck source=lib/bootstrap-data.sh
source lib/bootstrap-data.sh

mkdir -p logs
LOG_FILE="logs/setup-$(date '+%Y%m%d-%H%M%S').log"
export LOG_FILE

DO_UPDATE=0
DO_MIGRATE=0
DO_LITE=0
DO_RESET=0
DO_ROTATE_SECRET=0
SKIP_HEALTH_CHECKS=0
SEED_MODE=auto        # auto | on | off
SEED_ONLY=0
RESEED=0
export VERBOSE=0

for arg in "$@"; do
  case "$arg" in
    --update) DO_UPDATE=1 ;;
    --migrate) DO_MIGRATE=1 ;;
    --lite) DO_LITE=1 ;;
    --reset) DO_RESET=1 ;;
    --rotate-secret) DO_ROTATE_SECRET=1 ;;
    --skip-health-checks) SKIP_HEALTH_CHECKS=1 ;;
    --seed) SEED_MODE=on ;;
    --no-seed) SEED_MODE=off ;;
    --seed-only) SEED_ONLY=1 ;;
    --reseed) SEED_ONLY=1; RESEED=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./setup.sh [flags]

One-command bring-up for flow OverStack. With no flags: syncs submodules, starts
the stack, applies migrations on a first run, and seeds mock data on a first run.

  --seed            Force seeding on (default: only on a first run).
  --no-seed         Force seeding off.
  --seed-only       Skip the bring-up; just seed an already-running stack.
  --reseed          --seed-only, ignoring the "already seeded" check.
  --lite            Also skip Kibana and Grafana.
  --update          git submodule update --remote - move submodules to branch tips.
  --migrate         Re-apply the migration override after a schema change.
  --rotate-secret   Generate a new KC_ADMIN_TOKEN and push it into a running Keycloak.
  --skip-health-checks  Don't fail the run if a service's container/health checks
                        don't pass - log and move on instead. For debugging a
                        service in isolation, not for a normal run.
  --reset           teardown.sh --volumes, then a full setup from a clean slate.
  --verbose         Stream raw docker compose output to the console.
  -h, --help        Show this help.

See README.md for the details behind each flag.
EOF
      exit 0
      ;;
    *)
      log_fail "Unknown flag: $arg"
      exit 1
      ;;
  esac
done

COMPOSE="docker compose --env-file .env"
USER_COMPOSE="$COMPOSE -p flowoverstack -f repos/UserService/docker-compose.common.yml -f overrides/common.override.yml"

if [ "$DO_RESET" = "1" ]; then
  log_step "Reset requested - tearing down (with volumes) before setup"
  ./teardown.sh --volumes
fi

if [ "$SEED_ONLY" = "1" ]; then
  log_step "Seed-only run"
  if [ ! -f .env ]; then
    log_fail "No .env found - the stack has never been set up here. Run ./setup.sh first."
    exit 1
  fi
  # The seeder needs KC_ADMIN_TOKEN (to grant the first Admin) and REDIS_PASSWORD
  # (to drop stale reputation cache keys between phases).
  # shellcheck disable=SC1091
  set -a; source .env; set +a
  SEED_ARGS=()
  [ "$RESEED" = "1" ] && SEED_ARGS+=(--reseed)
  KC_HOST=http://localhost:8080 node seed/seed.mjs "${SEED_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
  exit "${PIPESTATUS[0]}"
fi

preflight

# --- 1. .env -------------------------------------------------------------
if [ ! -f .env ]; then
  log_step "Creating .env from .env.example"
  cp .env.example .env
fi
# shellcheck disable=SC1091
set -a; source .env; set +a

# Keycloak only imports a realm that doesn't already exist yet - if a Keycloak
# volume from a previous run is still around, --import-realm is a silent no-op
# and whatever secret is already baked into that realm stays authoritative.
# Blindly generating a new KC_ADMIN_TOKEN in that situation writes a value into
# .env that Keycloak will never recognize, and every later step fails.
KEYCLOAK_VOLUME_EXISTS=0
if docker volume ls -q 2>/dev/null | grep -q '^flowoverstack_keycloak_db_data$'; then
  KEYCLOAK_VOLUME_EXISTS=1
fi

OLD_KC_ADMIN_TOKEN="${KC_ADMIN_TOKEN:-}"
ROTATE_PENDING=0

if [ "$DO_ROTATE_SECRET" = "1" ]; then
  if [ -z "$OLD_KC_ADMIN_TOKEN" ]; then
    log_fail "--rotate-secret needs the current KC_ADMIN_TOKEN in .env to authenticate the rotation - none found."
    exit 1
  fi
  if [ "$KEYCLOAK_VOLUME_EXISTS" != "1" ]; then
    log_fail "--rotate-secret only makes sense against an already-provisioned Keycloak. No Keycloak volume found - just run ./setup.sh."
    exit 1
  fi
  KC_ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | cut -c1-32)
  sed -i "s|^KC_ADMIN_TOKEN=.*|KC_ADMIN_TOKEN=${KC_ADMIN_TOKEN}|" .env
  ROTATE_PENDING=1
  log_step "Generated a new KC_ADMIN_TOKEN - will push it to Keycloak once it's reachable"
elif [ -z "${KC_ADMIN_TOKEN:-}" ]; then
  if [ "$KEYCLOAK_VOLUME_EXISTS" = "1" ]; then
    log_fail "KC_ADMIN_TOKEN is missing from .env, but a Keycloak volume from a previous setup already exists."
    log_fail "Generating a fresh one here would NOT match the secret already stored inside that Keycloak - every later step would fail."
    log_fail "Fix: either restore the real secret (Keycloak admin console -> Clients -> user-service -> Credentials) into .env,"
    log_fail "     or start clean:  ./teardown.sh --volumes && ./setup.sh"
    exit 1
  fi
  KC_ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | cut -c1-32)
  if grep -q '^KC_ADMIN_TOKEN=' .env; then
    sed -i "s|^KC_ADMIN_TOKEN=.*|KC_ADMIN_TOKEN=${KC_ADMIN_TOKEN}|" .env
  else
    echo "KC_ADMIN_TOKEN=${KC_ADMIN_TOKEN}" >>.env
  fi
  log_step "Generated a new KC_ADMIN_TOKEN"
fi
export KC_ADMIN_TOKEN

# --- 2. submodules ---------------------------------------------------------
# Sparse-checkout state lives in each submodule's local .git/info/sparse-checkout,
# which is never committed or cloned - so it has to be (re-)applied here on every
# run, not just once. --no-cone patterns are gitignore-style; MSYS_NO_PATHCONV
# stops Git Bash from mangling a leading "/" into a Windows path.
log_step "Syncing submodules"
git submodule sync --recursive | tee -a "$LOG_FILE"
if [ "$DO_UPDATE" = "1" ]; then
  git submodule update --init --remote --recursive --depth 1 --force | tee -a "$LOG_FILE"
else
  git submodule update --init --recursive --depth 1 | tee -a "$LOG_FILE"
fi

log_step "Applying sparse-checkout (configs only, no full source)"
sparse() {
  local repo="$1"; shift
  git -C "repos/$repo" config core.sparseCheckout true
  MSYS_NO_PATHCONV=1 git -C "repos/$repo" sparse-checkout set --no-cone "$@" >>"$LOG_FILE" 2>&1
}
sparse UserService /docker-compose.yml /docker-compose.common.yml /logstash.conf /prometheus.yml
sparse QuestionService /docker-compose.yml /logstash.conf
sparse AnswerService /docker-compose.yaml /logstash.conf
sparse NotificationService /docker-compose.yaml /logstash.conf
# ApolloGateway is deliberately NOT sparse - `docker compose build` needs its full source.

# --- 3. realm import material (generated, gitignored) ----------------------
log_step "Preparing Keycloak realm import"
mkdir -p .keycloak-import
sed "s/__KC_ADMIN_TOKEN__/${KC_ADMIN_TOKEN}/" keycloak/flowOverStack-realm.json \
  >.keycloak-import/flowOverStack-realm.json

# --- 4. common stack ---------------------------------------------------------
log_step "Starting common infrastructure (Keycloak, Kafka, observability)"
if [ "$DO_LITE" = "1" ]; then
  log_run $USER_COMPOSE up -d --scale kibana=0 --scale grafana=0
else
  log_run $USER_COMPOSE up -d
fi || {
  log_fail "docker compose failed to bring up the common infrastructure - see $LOG_FILE"
  exit 1
}

log_step "Waiting for Keycloak"
wait_http "http://localhost:8080/realms/flowOverStack" 300 200 || { on_wait_fail identity-server; exit 1; }
log_ok "Keycloak realm imported"

if [ "$ROTATE_PENDING" = "1" ]; then
  log_step "Pushing the new KC_ADMIN_TOKEN into Keycloak (authenticating with the old one)"
  node lib/rotate-keycloak-secret.mjs "http://localhost:8080" "$OLD_KC_ADMIN_TOKEN" "$KC_ADMIN_TOKEN" \
    2>&1 | tee -a "$LOG_FILE"
  [ "${PIPESTATUS[0]}" = "0" ] || exit 1
  log_ok "Secret rotated"
fi

log_step "Waiting for Kafka broker, Elasticsearch, Prometheus"
# Kafka can take up to ~5 minutes cold (KRaft storage format + log recovery);
# Elasticsearch/Prometheus are usually well under 2 minutes. Timeouts below
# carry margin over both rather than matching them exactly.
wait_kafka_broker broker 360 || { on_wait_fail broker; exit 1; }
wait_http "http://localhost:9200" 150 || { on_wait_fail elasticsearch-elk; exit 1; }
wait_http "http://localhost:9090/-/ready" 150 200 || { on_wait_fail prometheus; exit 1; }
log_ok "Common infrastructure is up"

# --- 5. assert Keycloak client works ----------------------------------------
log_step "Verifying the user-service Keycloak client"
KC_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/flowOverStack/protocol/openid-connect/token" \
  -H 'content-type: application/x-www-form-urlencoded' \
  -d "client_id=user-service&client_secret=${KC_ADMIN_TOKEN}&grant_type=client_credentials" \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{process.stdout.write(JSON.parse(d).access_token||'')}catch{}})")
if [ -z "$KC_TOKEN" ]; then
  log_fail "Could not obtain a client_credentials token for user-service."
  log_fail "Either the realm import failed, or KC_ADMIN_TOKEN in .env doesn't match the secret already stored in Keycloak"
  log_fail "(this happens if .env was lost/regenerated against a Keycloak volume from a previous run)."
  log_fail "Fix: restore the real secret into .env, or  ./teardown.sh --volumes && ./setup.sh  to start clean."
  exit 1
fi
KC_USERS_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "authorization: Bearer $KC_TOKEN" \
  "http://localhost:8080/admin/realms/flowOverStack/users")
if [ "$KC_USERS_STATUS" != "200" ]; then
  log_fail "Admin API check failed (HTTP $KC_USERS_STATUS) - user-service client is missing realm-management roles"
  exit 1
fi
log_ok "user-service Keycloak client verified"

# --- 6. services -------------------------------------------------------------
FIRST_RUN=0
[ -f .setup-complete ] || FIRST_RUN=1

up_service() {
  local name="$1" compose_file="$2" project="$3"
  local cmd="$COMPOSE -p $project -f repos/$name/$compose_file"
  if [ "$FIRST_RUN" = "1" ] || [ "$DO_MIGRATE" = "1" ]; then
    cmd="$cmd -f overrides/migrate/$(echo "$name" | sed -E 's/([a-z])([A-Z])/\1-\2/g' | tr '[:upper:]' '[:lower:]').yml"
  fi
  log_step "Starting $name"
  log_run $cmd up -d || {
    log_fail "docker compose failed to start $name - see $LOG_FILE"
    exit 1
  }
}

up_service UserService docker-compose.yml userservice
up_service QuestionService docker-compose.yml questionservice
up_service AnswerService docker-compose.yaml answerservice
up_service NotificationService docker-compose.yaml notificationservice

check_service() {
  local kind="$1" name="$2" target="$3" timeout="$4"
  if [ "$SKIP_HEALTH_CHECKS" = "1" ]; then
    log_warn "Skipping $kind check for $name (--skip-health-checks)"
    return 0
  fi
  case "$kind" in
    container) wait_container_running "$target" "$timeout" ;;
    http) wait_health "$target" "$timeout" ;;
  esac || { on_wait_fail "$name"; exit 1; }
}

log_step "Waiting for services to apply migrations and boot"
sleep 5 # migrations run before Kestrel starts listening; avoid a tight 000 loop
check_service container user-service user-service 90
check_service container question-service question-service 90
check_service container answer-service answer-service 90
check_service container notification-service notification-service 90

log_step "Waiting for /health on all four services"
check_service http user-service "http://localhost:8085/health" 180
check_service http question-service "http://localhost:8087/health" 180
check_service http answer-service "http://localhost:8089/health" 180
check_service http notification-service "http://localhost:8091/health" 180
log_ok "All services are healthy (or skipped per --skip-health-checks)"

# --- 7. bootstrap reference data (roles, vote types) ------------------------
# Runs after the /health wait so migrations are guaranteed to have completed -
# a fresh --reset run races the app's own migration step otherwise, and this
# INSERTs into tables the migration creates.
if [ "$SKIP_HEALTH_CHECKS" = "1" ]; then
  log_warn "Skipping reference-data bootstrap (--skip-health-checks means migrations aren't confirmed done)"
else
  bootstrap_reference_data
fi

if [ "$FIRST_RUN" = "1" ] || [ "$DO_MIGRATE" = "1" ]; then
  touch .setup-complete
fi

# --- 8. gateway ---------------------------------------------------------------
log_step "Composing and starting the Apollo Gateway"
(
  cd repos/ApolloGateway
  export APOLLO_ELV2_LICENSE=accept
  # The subgraphs just cleared their /health gate, but their /graphql endpoint
  # (a bigger first request) isn't always warmed up yet - retry a couple times
  # before giving up on what's usually just a few more seconds of JIT warmup.
  ok=0
  for attempt in 1 2 3; do
    if npx -y @apollo/rover@latest supergraph compose --config supergraph.docker.yaml \
      >supergraph.graphql.tmp 2>>"$SETUP_ROOT/$LOG_FILE"; then
      ok=1
      break
    fi
    rm -f supergraph.graphql.tmp
    [ "$attempt" -lt 3 ] && sleep 10
  done
  [ "$ok" = "1" ] || exit 1
  mv supergraph.graphql.tmp supergraph.graphql
  docker compose up -d >>"$SETUP_ROOT/$LOG_FILE" 2>&1 || exit 1
) || {
  log_fail "Apollo Gateway build failed (rover supergraph compose, or the image build) - see $LOG_FILE"
  exit 1
}
wait_http "http://localhost:5000/graphql" 60 400 || { on_wait_fail apollo-gateway; exit 1; }
log_ok "Gateway is up"

# --- 9. seed -------------------------------------------------------------------
DO_SEED=0
if [ "$SEED_MODE" = "on" ]; then DO_SEED=1; fi
if [ "$SEED_MODE" = "auto" ] && [ "$FIRST_RUN" = "1" ]; then DO_SEED=1; fi

if [ "$DO_SEED" = "1" ]; then
  log_step "Seeding mock data"
  KC_HOST=http://localhost:8080 KC_ADMIN_TOKEN="$KC_ADMIN_TOKEN" REDIS_PASSWORD="$REDIS_PASSWORD" \
    node seed/seed.mjs 2>&1 | tee -a "$LOG_FILE"
else
  log_step "Skipping seed (use --seed or --seed-only to run it)"
fi

# --- 10. summary ----------------------------------------------------------------
cat <<EOF | tee -a "$LOG_FILE"

flow OverStack is up.

  UserService          http://localhost:8085/swagger  (GraphQL: /graphql)
  QuestionService       http://localhost:8087/swagger  (GraphQL: /graphql)
  AnswerService         http://localhost:8089/swagger  (GraphQL: /graphql)
  NotificationService   http://localhost:8091/swagger  (SignalR: /hubs/notifications)
  Apollo Gateway        http://localhost:5000/graphql
  Keycloak              http://localhost:8080  (admin: ${KC_BOOTSTRAP_ADMIN_USERNAME})
  Grafana               http://localhost:3000  (${GF_SECURITY_ADMIN_USER})
  Kibana                http://localhost:5601
  Jaeger                http://localhost:16686

Deferred (run './extras.sh up <name>' to start): control-center, connect,
rest-proxy, schema-registry, flink-jobmanager, flink-taskmanager, flink-sql-client,
aspire-dashboard, pgadmin.

Full log: $LOG_FILE
EOF
