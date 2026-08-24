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
  docker exec -i postgres-user-db psql -U postgres -d user-service-db -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO "Role" ("Name")
SELECT v FROM (VALUES ('User'), ('Admin'), ('Moderator')) AS t(v)
WHERE NOT EXISTS (SELECT 1 FROM "Role" WHERE "Name" = t.v);
SQL
  log_ok "Role table bootstrapped"
}

# bootstrap_vote_types <container> <database>
# MinReputationToVote is left at its schema default (0) so a brand-new user can
# vote immediately - bootstrap_reputation_rules below seeds the table that lets
# reputation actually accrue, but nothing should depend on the timing between
# the two, so voting is never gated on it.
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

# bootstrap_reputation_rules
# Without a matching row, ReputationService.ApplyReputationEventAsync returns
# BaseResult.Failure(ReputationRulesNotFound) - non-fatal (BaseEventConsumer just
# logs a warning and moves on, per ReputationService.cs/BaseEventConsumer.cs), but
# it means every seeded user's reputation silently stays 0 forever.
#
# Only EventType in {EntityAccepted, EntityUpvoted, EntityDownvoted} ever look up
# a rule (ApplyReputationEventAsync's default switch branch) - EntityDeleted,
# EntityVoteRemoved, and EntityAcceptanceRevoked only disable existing
# ReputationRecord rows and need no rule of their own. EntityAccepted only ever
# fires with EntityType=Answer (AnswerController exposes /accept; QuestionController
# does not), so that combination is the only one seeded for EntityAccepted.
#
# ReputationTarget=0 (Author) is required for a rule to do anything at all - if
# missing, the whole event is discarded even if an Initiator-target row exists
# (see the `if (!authorResult.IsSuccess) return authorResult;` short-circuit).
# ReputationTarget=1 (Initiator) is explicitly optional per a comment in
# ReputationService.cs ("There can be no rules for initiator") - deliberately not
# seeded here to avoid inventing reputation semantics beyond what the code confirms.
#
# Group is null-safe by default (DisableReputationRecordsAsync only acts when
# Group is non-null and matches), so it only needs a value where the domain
# behavior it exists for actually applies: auto-disabling a user's prior vote
# reputation record when they flip their vote on the same entity. Upvote/Downvote
# on the same EntityType share a Group for that reason; EntityAccepted has none,
# since acceptance is undone via the separate EntityAcceptanceRevoked event path.
#
# ReputationChange point values are illustrative dev-seed defaults (loosely
# Stack-Overflow-shaped), not derived from anything in the codebase - edit freely.
bootstrap_reputation_rules() {
  log_step "Bootstrapping ReputationRule table in UserService DB"
  docker exec -i postgres-user-db psql -U postgres -d user-service-db -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO "ReputationRule" ("EventType", "EntityType", "Group", "ReputationChange", "ReputationTarget")
SELECT v.event_type, v.entity_type, v.grp, v.change, 0
FROM (VALUES
  ('EntityUpvoted',   'Question', 'QuestionVote', 5),
  ('EntityDownvoted', 'Question', 'QuestionVote', -2),
  ('EntityUpvoted',   'Answer',   'AnswerVote',   10),
  ('EntityDownvoted', 'Answer',   'AnswerVote',   -2),
  ('EntityAccepted',  'Answer',   NULL,           15)
) AS v(event_type, entity_type, grp, change)
WHERE NOT EXISTS (
  SELECT 1 FROM "ReputationRule" r
  WHERE r."EventType" = v.event_type AND r."EntityType" = v.entity_type AND r."ReputationTarget" = 0
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
