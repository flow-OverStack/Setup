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
#   - UserService: reputation events silently no-op without a matching ReputationRule
#     row - see bootstrap_reputation_rules below for why that's non-fatal but still
#     worth fixing.
#
# Each INSERT is idempotent (WHERE NOT EXISTS) so re-running setup.sh is safe.
# Worth fixing properly upstream with an EF migration seed; this is the workaround
# until then.

bootstrap_user_roles() {
  log_step "Bootstrapping Role table (User/Admin/Moderator) in UserService DB"
  docker exec -i postgres-user-db psql -U postgres -d user-service-db -v ON_ERROR_STOP=1 -q <<'SQL' || { log_fail "Role table bootstrap failed - see output above"; exit 1; }
INSERT INTO "Role" ("Name")
SELECT v FROM (VALUES ('User'), ('Admin'), ('Moderator')) AS t(v)
WHERE NOT EXISTS (SELECT 1 FROM "Role" WHERE "Name" = t.v);
SQL
  log_ok "Role table bootstrapped"
}

bootstrap_vote_types() {
  local container="$1" database="$2"
  log_step "Bootstrapping VoteType table (Upvote/Downvote) in $database"
  docker exec -i "$container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 -q <<'SQL' || { log_fail "VoteType table bootstrap failed for $database - see output above"; exit 1; }
INSERT INTO "VoteType" ("Name", "MinReputationToVote", "ReputationChange")
SELECT v.name, v.min_rep, v.change
FROM (VALUES ('Upvote', 15, 1), ('Downvote', 125, -1)) AS v(name, min_rep, change)
WHERE NOT EXISTS (SELECT 1 FROM "VoteType" WHERE "Name" = v.name);
SQL
  log_ok "VoteType table bootstrapped in $database"
}

bootstrap_reputation_rules() {
  log_step "Bootstrapping ReputationRule table in UserService DB"
  docker exec -i postgres-user-db psql -U postgres -d user-service-db -v ON_ERROR_STOP=1 -q <<'SQL' || { log_fail "ReputationRule table bootstrap failed - see output above"; exit 1; }
INSERT INTO "ReputationRule" ("EventType", "EntityType", "Group", "ReputationChange", "ReputationTarget")
SELECT v.event_type, v.entity_type, v.grp, v.change, v.target
FROM (VALUES
  ('EntityAccepted',   'Answer',   NULL,   15, 0),
  ('EntityDownvoted',  'Answer',   'Vote', -1, 1),
  ('EntityDownvoted',  'Answer',   'Vote', -2, 0),
  ('EntityUpvoted',    'Answer',   'Vote', 10, 0),
  ('EntityAccepted',   'Answer',   NULL,    2, 1),
  ('EntityDownvoted',  'Question', 'Vote', -2, 0),
  ('EntityUpvoted',    'Question', 'Vote', 10, 0)
) AS v(event_type, entity_type, grp, change, target)
WHERE NOT EXISTS (
  SELECT 1 FROM "ReputationRule" r
  WHERE r."EventType" = v.event_type AND r."EntityType" = v.entity_type
    AND r."ReputationTarget" = v.target AND r."Group" IS NOT DISTINCT FROM v.grp
);
SQL
  log_ok "ReputationRule table bootstrapped"
}

bootstrap_reference_data() {
  bootstrap_user_roles
  bootstrap_vote_types postgres-question-db question-service-db
  bootstrap_vote_types postgres-answer-db answer-service-db
  bootstrap_reputation_rules
}
