#!/usr/bin/env node
// Static checks on seed/data.json. No running stack needed - run it after editing
// the fixtures: `node seed/verify-data.mjs`
//
// The important thing it proves is that the seed is *self-bootstrapping*. Reputation
// is earned through the real API (accept -> upvote -> downvote), and each of those
// steps has an entry requirement:
//   - accepting needs no reputation, only question ownership  (AcceptAnswerHandler)
//   - upvoting needs 15   (VoteType.MinReputationToVote)
//   - downvoting needs 125
// So the fixtures only work if, at each phase, every actor already cleared the bar
// using reputation earned in earlier phases. This replays that math with the same
// rules bootstrap-data.sh seeds and the same clamp GetCurrentReputationsAsync applies.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const data = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'data.json'), 'utf-8'));

// Mirrors lib/bootstrap-data.sh. [target, points] where target is author|initiator.
const RULES = {
  'EntityAccepted:Answer:author': 15,
  'EntityAccepted:Answer:initiator': 2,
  'EntityUpvoted:Answer:author': 10,
  'EntityUpvoted:Question:author': 10,
  'EntityDownvoted:Answer:author': -2,
  'EntityDownvoted:Answer:initiator': -1,
  'EntityDownvoted:Question:author': -2,
};

const MIN_REPUTATION = 1; // BusinessRules.MinReputation
const MAX_DAILY_REPUTATION = 200; // BusinessRules.MaxDailyReputation
const MIN_REP_UPVOTE = 15; // VoteTypeMother.cs
const MIN_REP_DOWNVOTE = 125;

// username -> [min, max] the seed intends. Not in data.json on purpose: data.json
// holds only what the public API consumes; this is an assertion about the outcome.
const TIERS = {
  alice: [MIN_REP_DOWNVOTE, Infinity],
  bob: [MIN_REP_DOWNVOTE, Infinity],
  carol: [MIN_REP_UPVOTE, MIN_REP_DOWNVOTE - 1],
  dave: [MIN_REP_UPVOTE, MIN_REP_DOWNVOTE - 1],
  erin: [0, MIN_REP_UPVOTE - 1],
  frank: [0, MIN_REP_UPVOTE - 1],
};

const errors = [];
const usernames = new Set(data.users.map((u) => u.username));
const tagNames = new Set(data.tags.map((t) => t.name));

// All seeded activity happens on one calendar day, so every user is a single
// (user, date) group - which is also what keeps GrpcUserService's .Single() safe.
const raw = Object.fromEntries(data.users.map((u) => [u.username, 0]));
const clamp = (n) => Math.max(MIN_REPUTATION, Math.min(n, MAX_DAILY_REPUTATION));
const rep = (u) => clamp(raw[u]);
const award = (user, ruleKey) => {
  if (RULES[ruleKey] === undefined) throw new Error(`no rule ${ruleKey}`);
  raw[user] += RULES[ruleKey];
};

// ---- structural checks -------------------------------------------------------
for (const q of data.questions) {
  const where = `question "${q.title.slice(0, 40)}..."`;
  if (!usernames.has(q.askedBy)) errors.push(`${where}: unknown askedBy "${q.askedBy}"`);
  if (q.title.length < 10 || q.title.length > 150) errors.push(`${where}: title length ${q.title.length}, must be 10..150`);
  if (q.body.length < 30) errors.push(`${where}: body length ${q.body.length}, must be >= 30`);
  if (q.tags.length < 1 || q.tags.length > 5) errors.push(`${where}: ${q.tags.length} tags, must be 1..5`);
  for (const t of q.tags) if (!tagNames.has(t)) errors.push(`${where}: unknown tag "${t}"`);

  for (const v of q.votes) {
    if (!usernames.has(v.by)) errors.push(`${where}: unknown voter "${v.by}"`);
    if (v.by === q.askedBy) errors.push(`${where}: self-vote by ${v.by} (CannotVoteForOwnPost)`);
  }
  for (const vw of q.views) if (vw.by && !usernames.has(vw.by)) errors.push(`${where}: unknown viewer "${vw.by}"`);

  if (q.answers.filter((a) => a.accepted).length > 1) {
    errors.push(`${where}: more than one accepted answer (QuestionAlreadyHasAcceptedAnswer)`);
  }
  for (const a of q.answers) {
    if (!usernames.has(a.answeredBy)) errors.push(`${where}: unknown answeredBy "${a.answeredBy}"`);
    if (a.body.length < 30) errors.push(`${where}: answer body length ${a.body.length}, must be >= 30`);
    for (const v of a.votes) {
      if (!usernames.has(v.by)) errors.push(`${where}: unknown answer voter "${v.by}"`);
      if (v.by === a.answeredBy) errors.push(`${where}: self-vote on own answer by ${v.by}`);
    }
  }
}

// ---- phase 1: accepts (no reputation required) -------------------------------
for (const q of data.questions) {
  for (const a of q.answers) {
    if (!a.accepted) continue;
    award(a.answeredBy, 'EntityAccepted:Answer:author');
    award(q.askedBy, 'EntityAccepted:Answer:initiator');
  }
}
const afterAccepts = Object.fromEntries(data.users.map((u) => [u.username, rep(u.username)]));

// ---- phase 2: upvotes (voter needs >= 15, earned above) ----------------------
for (const q of data.questions) {
  for (const v of q.votes.filter((v) => v.direction === 'upvote')) {
    if (afterAccepts[v.by] < MIN_REP_UPVOTE) {
      errors.push(`upvote by ${v.by} on a question: has ${afterAccepts[v.by]} rep after accepts, needs ${MIN_REP_UPVOTE} (403 TooLowReputation)`);
    }
    award(q.askedBy, 'EntityUpvoted:Question:author');
  }
  for (const a of q.answers) {
    for (const v of a.votes.filter((v) => v.direction === 'upvote')) {
      if (afterAccepts[v.by] < MIN_REP_UPVOTE) {
        errors.push(`upvote by ${v.by} on an answer: has ${afterAccepts[v.by]} rep after accepts, needs ${MIN_REP_UPVOTE}`);
      }
      award(a.answeredBy, 'EntityUpvoted:Answer:author');
    }
  }
}
const afterUpvotes = Object.fromEntries(data.users.map((u) => [u.username, rep(u.username)]));

// ---- phase 3: downvotes (voter needs >= 125, earned above) -------------------
for (const q of data.questions) {
  for (const v of q.votes.filter((v) => v.direction === 'downvote')) {
    if (afterUpvotes[v.by] < MIN_REP_DOWNVOTE) {
      errors.push(`downvote by ${v.by} on a question: has ${afterUpvotes[v.by]} rep after upvotes, needs ${MIN_REP_DOWNVOTE}`);
    }
    award(q.askedBy, 'EntityDownvoted:Question:author');
    // no Initiator rule for question downvotes
  }
  for (const a of q.answers) {
    for (const v of a.votes.filter((v) => v.direction === 'downvote')) {
      if (afterUpvotes[v.by] < MIN_REP_DOWNVOTE) {
        errors.push(`downvote by ${v.by} on an answer: has ${afterUpvotes[v.by]} rep after upvotes, needs ${MIN_REP_DOWNVOTE}`);
      }
      award(a.answeredBy, 'EntityDownvoted:Answer:author');
      award(v.by, 'EntityDownvoted:Answer:initiator');
    }
  }
}

// ---- final tiers -------------------------------------------------------------
console.log('\n  user     after-accepts  after-upvotes  final   tier');
console.log('  ------------------------------------------------------');
for (const u of data.users) {
  const n = u.username;
  const final = rep(n);
  const [lo, hi] = TIERS[n] ?? [0, Infinity];
  const ok = final >= lo && final <= hi;
  if (!ok) errors.push(`${n}: final reputation ${final} outside intended tier [${lo}, ${hi === Infinity ? '∞' : hi}]`);
  const tier = final >= MIN_REP_DOWNVOTE ? 'up+down' : final >= MIN_REP_UPVOTE ? 'up only' : 'no votes';
  console.log(
    `  ${n.padEnd(8)} ${String(afterAccepts[n]).padStart(12)} ${String(afterUpvotes[n]).padStart(14)} ${String(final).padStart(7)}   ${tier}${ok ? '' : '  <-- WRONG'}`,
  );
}

const answerCount = data.questions.reduce((n, q) => n + q.answers.length, 0);
const acceptedCount = data.questions.filter((q) => q.answers.some((a) => a.accepted)).length;
const voteCount = data.questions.reduce((n, q) => n + q.votes.length + q.answers.reduce((m, a) => m + a.votes.length, 0), 0);
const viewCount = data.questions.reduce((n, q) => n + q.views.length, 0);
console.log(
  `\n  ${data.users.length} users, ${data.tags.length} tags, ${data.questions.length} questions, ` +
    `${answerCount} answers (${acceptedCount} accepted), ${voteCount} votes, ${viewCount} views`,
);
console.log(`  questions with multiple answers: ${data.questions.filter((q) => q.answers.length > 1).length}`);

if (errors.length) {
  console.error(`\n${errors.length} problem(s):`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
console.log('\n  all checks pass\n');
