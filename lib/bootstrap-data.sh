#!/usr/bin/env bash
# Sourced by setup.sh, run once right after migrations (per-service, first run only).
#
# This is NOT mock data - it's baseline reference data none of the four services'
# EF Core migrations seed, and the public API can't create either:
#
#   - UserService: /auth/register looks up a Role row named "User" and fails with
#     RoleNotFound if it's missing (AuthService.cs). RoleController - the only API
#     that can create a Role - requires the Admin role, which requires a Role row
#     to exist first. Circular: on a fresh DB nobody can ever register.
#   - QuestionService / AnswerService: voting 404s with VoteTypeNotFound until a
#     VoteType row named exactly "Upvote"/"Downvote" exists. Nothing seeds it.
#
# Each INSERT is idempotent (WHERE NOT EXISTS) so re-running setup.sh is safe.
# Worth fixing properly upstream with an EF migration seed; this is the workaround
# until then.

bootstrap_user_roles() {
  log_step "Bootstrapping Role table (User/Admin/Moderator) in UserService DB"
  docker exec -i postgres-user-db psql -U postgres -d user-service-db -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO "Role" ("Name")
SELECT v FROM (VALUES ('User'), ('Admin'), ('Moderator')) AS t(v)
WHERE NOT EXISTS (SELECT 1 FROM "Role" WHERE "Name" = t.v);
SQL
  log_ok "Role table bootstrapped"
}

# bootstrap_vote_types <container> <database>
# MinReputationToVote is left at its schema default (0) so a brand-new user can
# vote immediately - ReputationRule (the table that would let reputation accrue
# from votes) is likewise unseeded anywhere, so gating on reputation here would
# make voting permanently unreachable.
bootstrap_vote_types() {
  local container="$1" database="$2"
  log_step "Bootstrapping VoteType table (Upvote/Downvote) in $database"
  docker exec -i "$container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO "VoteType" ("Name", "MinReputationToVote", "ReputationChange")
SELECT v.name, 0, v.change
FROM (VALUES ('Upvote', 10), ('Downvote', -2)) AS v(name, change)
WHERE NOT EXISTS (SELECT 1 FROM "VoteType" WHERE "Name" = v.name);
SQL
  log_ok "VoteType table bootstrapped in $database"
}

bootstrap_reference_data() {
  bootstrap_user_roles
  bootstrap_vote_types postgres-question-db question-service-db
  bootstrap_vote_types postgres-answer-db answer-service-db
}
