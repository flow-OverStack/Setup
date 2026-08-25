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
# Values match VoteTypeMother.cs (QuestionService.Tests / AnswerService.Tests) exactly -
# the real intended production values, not a guess: 15 rep to upvote, 125 to downvote
# (mirrors Stack Overflow's actual privilege thresholds), +1/-1 is the per-post score
# delta (VoteType.ReputationChange - a LOCAL vote tally on the post itself, separate
# from a user's platform-wide reputation, which is ReputationRule.ReputationChange below).
bootstrap_vote_types() {
  local container="$1" database="$2"
  log_step "Bootstrapping VoteType table (Upvote/Downvote) in $database"
  docker exec -i "$container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO "VoteType" ("Name", "MinReputationToVote", "ReputationChange")
SELECT v.name, v.min_rep, v.change
FROM (VALUES ('Upvote', 15, 1), ('Downvote', 125, -1)) AS v(name, min_rep, change)
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
# These 7 rows are copied verbatim from ReputationRuleMother.cs (UserService.Tests) -
# the real intended rule set, not a guess (its 8th row, "TestSuperEvent", is test-only
# and skipped here). Only EventType in {EntityAccepted, EntityUpvoted, EntityDownvoted}
# ever look up a rule (ApplyReputationEventAsync's default switch branch) -
# EntityDeleted, EntityVoteRemoved, and EntityAcceptanceRevoked only disable existing
# ReputationRecord rows and need no rule of their own. EntityAccepted only ever fires
# with EntityType=Answer (AnswerController exposes /accept; QuestionController does
# not), so EntityType=Question+EntityAccepted is correctly absent.
#
# ReputationTarget=0 (Author) is required for a rule to do anything at all - if
# missing, the whole event is discarded even if an Initiator-target row exists (see
# the `if (!authorResult.IsSuccess) return authorResult;` short-circuit). Note the
# real rule set has NO Initiator-target rows for Question votes, and no Initiator
# reward for upvoting an Answer either - only downvoting an Answer costs the
# initiator rep (-1), and accepting an Answer rewards the initiator (+2, i.e. the
# asker gains reputation for accepting).
#
# Group="Vote" is what makes DisableReputationRecordsAsync auto-disable a user's
# prior vote record when they flip their vote on the same entity (it also checks
# EntityType, so sharing the literal string "Vote" across Question and Answer rows
# is correct, not a collision). EntityAccepted rows have no Group, since acceptance
# is undone via the separate EntityAcceptanceRevoked event path instead.
#
# ONE DELIBERATE DEVIATION from ReputationRuleMother.cs: it gives the
# EntityDownvoted/Answer/Initiator rule Group=NULL while its Author counterpart has
# Group='Vote'. ReputationService then runs
#     rules.Select(x => x.Group).Distinct().Single()
# over every rule matching (EventType, EntityType) - two distinct Groups make
# .Single() throw, so downvoting an answer would blow up in BaseEventConsumer and
# dead-letter the event. The service's own comment states the invariant ("Group is
# either NULL or identical across all ReputationRule records" for a given
# EventType+EntityType), so the mother data violates it; we set Group='Vote' on
# both to satisfy it. Worth fixing upstream in ReputationRuleMother.cs too.
bootstrap_reputation_rules() {
  log_step "Bootstrapping ReputationRule table in UserService DB"
  docker exec -i postgres-user-db psql -U postgres -d user-service-db -v ON_ERROR_STOP=1 -q <<'SQL'
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
