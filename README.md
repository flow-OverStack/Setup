# flow OverStack - setup

One-command bring-up for the [flow OverStack](https://github.com/flow-OverStack/.github/blob/main/profile/README.md)
platform: UserService, QuestionService, AnswerService, NotificationService, and the Apollo Gateway,
pulled in as git submodules, brought up with Docker Compose, and seeded with mock data.

## Prerequisites

- Docker Desktop (with Compose v2 - `docker compose version`, not the old `docker-compose`)
- Node.js (used to run the seeder and to invoke Rover for the gateway's supergraph)
- Git
- 8 GB+ RAM allocated to Docker (less works, but Elasticsearch/Kafka are prone to OOM-kills below that)
- **Windows**: Git Bash, which ships with [Git for Windows](https://git-scm.com/download/win). Run
  `.\setup.ps1` from PowerShell, or `./setup.sh` directly from a Git Bash / WSL shell.

## Quick start

```bash
git clone --recurse-submodules --shallow-submodules https://github.com/flow-OverStack/Setup
cd setup
./setup.sh
```

That's it. On first run this:

1. Syncs the five service submodules
2. Generates a `.env` (documented placeholder passwords, plus a fresh `KC_ADMIN_TOKEN`)
3. Imports a pre-configured Keycloak realm (no manual Keycloak setup)
4. Applies EF Core migrations on all four services
5. Bootstraps reference data the services need to function (see [Known gaps](#known-gaps-in-the-upstream-services))
6. Composes and starts the Apollo Gateway
7. Seeds 6 users, 8 tags, 12 questions, 17 answers, and votes through the real APIs

Takes roughly 10 minutes cold. Endpoints are printed at the end.

## Flags

| Flag | Effect |
|---|---|
| `--seed` / `--no-seed` | Force seeding on or off. Default: seed on a first run, skip on later runs. |
| `--seed-only` | Skip the whole bring-up and just run the seeder against an already-running stack. |
| `--reseed` | `--seed-only`, ignoring the "already seeded" check - re-seeds from scratch. |
| `--lite` | Also skip Kibana and Grafana. |
| `--update` | `git submodule update --remote` - move submodules to their branch tips first. |
| `--migrate` | Re-apply the migration override after a schema change. |
| `--rotate-secret` | Change `KC_ADMIN_TOKEN` on a stack that's already running - generates a new one and pushes it into Keycloak via the Admin API (authenticating with the current one). Needs an existing `.env` and Keycloak volume; the opposite of `--volumes`, not a follow-up to it. |
| `--verbose` | Stream raw `docker compose` output to the console. |
| `--reset` | `teardown.sh --volumes` then a full setup, from a clean slate. |

## Re-running against existing data

`setup.sh` is safe to run again on a stack that already has volumes from a previous run: Keycloak's
`--import-realm` no-ops on a realm that already exists, migrations and the reference-data bootstrap
are idempotent, and seeding is skipped by default once `.setup-complete` is present.

The one thing that must stay in sync with those volumes is `KC_ADMIN_TOKEN` in `.env` - it has to
match the secret already baked into the existing Keycloak realm, because import won't overwrite it.
If `.env` is lost (deleted, or a fresh clone pointed at old volumes) while a Keycloak volume still
exists, `setup.sh` refuses to blindly generate a new token - a mismatched one would fail every
downstream step - and tells you to either restore the real secret from the Keycloak admin console
(**Clients → user-service → Credentials**) or run with `--reset` flag to start clean.

## Teardown

```bash
./teardown.sh              # stop everything, keep your data
./teardown.sh --volumes    # also wipe all databases/Keycloak/Kafka data
./teardown.sh --images     # also remove the pulled/built Docker images
./teardown.sh --all        # --volumes --images, plus generated files
```

## Extras

Nine services from the shared Kafka/observability/admin stack aren't started by default because
nothing in the app needs them at runtime (control-center, connect, rest-proxy, schema-registry, the
three Flink services, aspire-dashboard, and pgadmin) - they add several GB of RAM and a good chunk of
cold-start time for tooling you may never open.

```bash
./extras.sh create              # create them, don't start
./extras.sh up                  # start all of them
./extras.sh up pgadmin          # start just one
./extras.sh down                # stop them
```

None of the nine are created or started unless you ask via `extras.sh` - `setup.sh` never touches them.

## Repo layout

```
setup.sh / teardown.sh / extras.sh   the three entry points
lib/                                 shell libraries (logging, readiness polling, preflight, DB bootstrap)
seed/                                mock-data fixtures and the seeder (Node)
keycloak/flowOverStack-realm.json    committed realm template (secret is a placeholder, substituted at setup time)
overrides/                           small compose overrides layered onto each submodule's own compose file
repos/                               the five service submodules (shallow, sparse-checked-out to just the configs setup needs)
.env / .env.example                  compose env vars (`.env` is gitignored - it holds a real secret)
logs/                                one timestamped log per setup.sh / teardown.sh run (gitignored)
```

The submodule compose files are never edited or copied - `overrides/*.yml` are layered on top with
`docker compose -f base -f override`, which deep-merges rather than replaces (see comments in
`overrides/common.override.yml` for the merge semantics). `git submodule update --force` is therefore
always safe to run.
