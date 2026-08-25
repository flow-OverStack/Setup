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
git clone --recurse-submodules --shallow-submodules <this-repo-url>
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
7. Seeds ~6 users, ~15 questions, answers, and votes through the real APIs

Takes roughly 3-6 minutes cold. Endpoints are printed at the end - also see the table in the
[profile README](https://github.com/flow-OverStack/.github/blob/main/profile/README.md), noting that
one is wrong: the profile lists the host `dotnet run` HTTPS ports (7163/7067/7216/7233); the Docker
containers here publish HTTP on 8085/8087/8089/8091.

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
(**Clients → user-service → Credentials**) or run `./teardown.sh --volumes` to start clean.

## Teardown

```bash
./teardown.sh              # stop everything, keep your data
./teardown.sh --volumes    # also wipe all databases/Keycloak/Kafka data
./teardown.sh --images     # also remove the pulled/built Docker images
./teardown.sh --all        # --volumes --images, plus generated files
```

## Extras

Eight services from the shared Kafka/observability stack aren't started by default because nothing in
the app needs them at runtime (control-center, connect, rest-proxy, schema-registry, the three Flink
services, and aspire-dashboard) - they add several GB of RAM and a good chunk of cold-start time for
tooling you may never open.

```bash
./extras.sh create              # create them, don't start
./extras.sh up                  # start all of them
./extras.sh up control-center   # start just one
./extras.sh down                # stop them
```

`aspire-dashboard` gets special treatment: `setup.sh` creates (but doesn't start) it automatically on
every run, since it's cheap and commonly wanted - `docker start aspire-dashboard` brings it up in
seconds. The other seven are neither created nor started unless you ask via `extras.sh`.

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

## Known gaps in the upstream services

Three things the setup repo works around that are arguably bugs in the service repos themselves,
documented here so nobody re-discovers them the hard way:

- **No seed data for `Role` or `VoteType`.** `/auth/register` looks up a `Role` row named `"User"`
  and fails outright if it's missing - on a truly fresh database, registration itself is broken, not
  just admin features. `RoleController` (the only API that can create a `Role`) requires the `Admin`
  role, which requires a `Role` row to exist first - circular. Voting similarly 404s until a
  `VoteType` row named `Upvote`/`Downvote` exists. `lib/bootstrap-data.sh` inserts both directly via
  `psql`, idempotently, right after migrations run. Worth fixing upstream with a proper EF Core seed
  migration in UserService, QuestionService, and AnswerService.
- **No seed data for `ReputationRule` either**, so every vote/accept event silently no-ops
  (`ReputationService.ApplyReputationEventAsync` returns a clean failure the Kafka consumer just logs
  and drops) and every user's reputation stays 0 forever. Non-fatal, unlike the two above - `psql`
  seeds five rules covering upvote/downvote/accept for questions and answers so seeded users show
  real reputation; the point values are illustrative dev defaults, not derived from the codebase, so
  edit them freely in `lib/bootstrap-data.sh`.
- **No way to grant the first Admin.** Same circularity as the `Role` gap, one level up: nothing in
  the public API can ever create the first Admin user. `seed/seed.mjs` works around it by calling the
  Keycloak Admin API directly (using the same `KC_ADMIN_TOKEN` client secret `setup.sh` already
  validates) to add `Admin` to one seed user's `roles` attribute, then re-logs them in for a token
  that carries it.
