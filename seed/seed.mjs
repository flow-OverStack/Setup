#!/usr/bin/env node
// Seeds flow OverStack with mock data through the public REST APIs. Nothing here
// fabricates domain state: users register, ask, answer, accept and vote exactly as
// a real client would, and reputation is *earned* from those actions via the
// outbox -> Kafka -> UserService path rather than being written into the DB.
//
// That earning is why this runs in phases. Each action has an entry requirement:
//   accept   - none beyond owning the question   (AcceptAnswerHandler)
//   upvote   - 15 reputation                     (VoteType.MinReputationToVote)
//   downvote - 125 reputation
// so the only way to bootstrap from a cold database is accept -> upvote -> downvote,
// waiting between phases for the reputation from the previous one to land.
// seed/verify-data.mjs replays that math over data.json without a running stack.
//
// Two infrastructure pokes are unavoidable between phases, neither of which invents
// data: polling Postgres to see whether the Kafka consumer has written the
// ReputationRecord rows yet, and dropping the Redis reputation keys so the services
// re-read them instead of serving a 300s-stale value.
//
// Idempotent: registration 409s on a second run and that is treated as
// "already seeded", so the whole run short-circuits.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { execFileSync } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const data = JSON.parse(readFileSync(join(__dirname, 'data.json'), 'utf-8'));

const USER_BASE = process.env.USER_SERVICE_URL ?? 'http://localhost:8085';
const QUESTION_BASE = process.env.QUESTION_SERVICE_URL ?? 'http://localhost:8087';
const ANSWER_BASE = process.env.ANSWER_SERVICE_URL ?? 'http://localhost:8089';
const NOTIFICATION_BASE = process.env.NOTIFICATION_SERVICE_URL ?? 'http://localhost:8091';
const KC_HOST = process.env.KC_HOST ?? 'http://localhost:8080';
const REDIS_PASSWORD = process.env.REDIS_PASSWORD ?? '';

const MIN_REP_UPVOTE = 15; // VoteType.MinReputationToVote, see lib/bootstrap-data.sh
const MIN_REP_DOWNVOTE = 125;
const REPUTATION_TIMEOUT_MS = 120_000; // outbox polls every 15s (OutboxBackgroundService)

const RESEED = process.argv.includes('--reseed');

const log = (m) => console.log(`[seed] ${m}`);
const warn = (m) => console.warn(`[seed] WARN: ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, url, { token, body, headers: extraHeaders } = {}) {
  const headers = { 'content-type': 'application/json', ...extraHeaders };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(url, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try {
    json = await res.json();
  } catch {
    // empty body (e.g. 204) is fine
  }
  return { status: res.status, ok: res.ok, body: json };
}

const unwrap = (res) => res.body?.data ?? res.body; // BaseResult<T> wraps payloads in .data

// ---------------------------------------------------------------- users

async function registerUser(u) {
  const res = await api('POST', `${USER_BASE}/api/v1/auth/register`, {
    body: { username: u.username, email: u.email, password: u.password },
  });
  if (res.status === 409) return 'exists';
  if (!res.ok) throw new Error(`register ${u.username} failed: ${res.status} ${JSON.stringify(res.body)}`);
  return 'created';
}

async function loginUser(u) {
  const res = await api('POST', `${USER_BASE}/api/v1/auth/login`, {
    body: { identifier: u.username, password: u.password },
  });
  if (!res.ok) throw new Error(`login ${u.username} failed: ${res.status} ${JSON.stringify(res.body)}`);
  return unwrap(res).accessToken;
}

async function initUser(token) {
  // Normally the frontend's job after registration. Idempotent - returns the
  // existing UserDto once the local row exists, so it doubles as "what is this
  // user's numeric id", which every later phase needs.
  const res = await api('POST', `${USER_BASE}/api/v1/auth/init`, { token });
  if (!res.ok) throw new Error(`init failed: ${res.status} ${JSON.stringify(res.body)}`);
  return unwrap(res).id;
}

async function promoteToAdmin(username) {
  // Nothing in the public API can grant the first Admin - RoleController itself
  // requires Admin. See lib/bootstrap-data.sh for the full circularity writeup.
  const adminSecret = process.env.KC_ADMIN_TOKEN;
  const realm = 'flowOverStack';

  const tokenRes = await fetch(`${KC_HOST}/realms/${realm}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: 'user-service',
      client_secret: adminSecret,
      grant_type: 'client_credentials',
    }),
  });
  if (!tokenRes.ok) throw new Error(`Keycloak client_credentials token fetch failed: ${tokenRes.status}`);
  const { access_token: kcToken } = await tokenRes.json();

  const findRes = await fetch(`${KC_HOST}/admin/realms/${realm}/users?username=${username}&exact=true`, {
    headers: { authorization: `Bearer ${kcToken}` },
  });
  const kcUser = (await findRes.json())[0];
  if (!kcUser) throw new Error(`Keycloak user ${username} not found - register/login must run first`);

  const roles = new Set(kcUser.attributes?.roles ?? []);
  roles.add('Admin');

  const updateRes = await fetch(`${KC_HOST}/admin/realms/${realm}/users/${kcUser.id}`, {
    method: 'PUT',
    headers: { authorization: `Bearer ${kcToken}`, 'content-type': 'application/json' },
    body: JSON.stringify({ attributes: { ...kcUser.attributes, roles: [...roles] } }),
  });
  if (!updateRes.ok) throw new Error(`Failed to grant Admin to ${username}: ${updateRes.status}`);
}

// ------------------------------------------------- reputation propagation

// Reads reputation straight from Postgres using the same expression
// GetUserService.GetCurrentReputationsAsync computes in LINQ: group by (user, day),
// clamp each day's summed rule deltas into [MinReputation, MaxDailyReputation].
// The per-day grouping is there to apply the *daily* cap, so a user's total is the
// sum of their clamped per-day values - hence the nested aggregate below. Grouping
// per day and stopping there would return one row per (user, day), and the loop
// underneath would silently keep only the last one: fine within a single seeding
// session, wrong for any run that crosses UTC midnight, where the vote gates in
// phases 3 and 4 would then wait out their full timeout for a threshold already met.
//
// Two knowing deviations from the LINQ, both conservative:
//   - `WHERE rr."Enabled"` has no counterpart in the method; GetAll() may apply it
//     as a global query filter. Seeded data never disables records either way.
//   - 1 and 200 hardcode BusinessRules.MinReputation / MaxDailyReputation, which
//     aren't visible under the sparse checkout.
//
// Reading the source of truth (rather than an API) tells us specifically whether
// the Kafka consumer has landed the rows yet, with no cache in the way.
function readReputations() {
  const sql = `
SELECT d."ReputationTargetId", SUM(d.daily)
FROM (
  SELECT rr."ReputationTargetId",
         GREATEST(1, LEAST(SUM(ru."ReputationChange"), 200)) AS daily
  FROM "ReputationRecord" rr
  JOIN "ReputationRule" ru ON ru."Id" = rr."ReputationRuleId"
  WHERE rr."Enabled"
  GROUP BY rr."ReputationTargetId", rr."CreatedAt"::date
) d
GROUP BY d."ReputationTargetId";`;
  const out = execFileSync(
    'docker',
    ['exec', '-i', 'postgres-user-db', 'psql', '-U', 'postgres', '-d', 'user-service-db', '-t', '-A', '-F', '|', '-c', sql],
    { encoding: 'utf-8' },
  );
  const byId = {};
  for (const line of out.split('\n')) {
    const [id, value] = line.trim().split('|');
    if (id && value) byId[Number(id)] = Number(value);
  }
  return byId;
}

// GetCurrentReputationsAsync is cached in Redis for RedisSettings TimeToLiveInSeconds
// (300s in docker-compose). Without dropping the keys, a service that read a user's
// reputation before it changed keeps serving the old number for five minutes, and
// every vote gated on it would 403. Deleting a cache entry invents nothing.
function flushReputationCache() {
  const lua = "local n=0 for _,k in ipairs(redis.call('keys','user:*reputation')) do redis.call('del',k) n=n+1 end return n";
  try {
    execFileSync(
      'docker',
      ['exec', 'redis-user-service', 'redis-cli', '--no-auth-warning', '-a', REDIS_PASSWORD, 'EVAL', lua, '0'],
      { stdio: ['ignore', 'ignore', 'pipe'] },
    );
  } catch (e) {
    warn(`could not flush the Redis reputation cache: ${e.message}`);
  }
}

// Waits for earned reputation to travel outbox -> Kafka -> UserService, then drops
// the cache so the next phase's gate checks see the new values.
async function waitForReputation(requirements, userIds, label) {
  const names = Object.keys(requirements);
  if (names.length === 0) return;
  const need = names.map((n) => `${n}>=${requirements[n]}`).join(' ');
  log(`waiting for reputation to propagate (${label}: ${need})`);

  const started = Date.now();
  let last = {};
  while (Date.now() - started < REPUTATION_TIMEOUT_MS) {
    const byId = readReputations();
    last = Object.fromEntries(names.map((n) => [n, byId[userIds[n]] ?? 1]));
    if (names.every((n) => last[n] >= requirements[n])) {
      flushReputationCache();
      const secs = ((Date.now() - started) / 1000).toFixed(0);
      log(`reputation ready after ${secs}s (${names.map((n) => `${n}=${last[n]}`).join(' ')})`);
      return;
    }
    await sleep(3000);
  }
  warn(
    `timed out after ${REPUTATION_TIMEOUT_MS / 1000}s waiting for ${label}. ` +
      `Current: ${names.map((n) => `${n}=${last[n] ?? '?'}`).join(' ')}. ` +
      `The outbox -> Kafka -> UserService path may be stalled; votes needing reputation will be rejected below.`,
  );
  flushReputationCache();
}

// ---------------------------------------------------------------- content

async function ensureTag(token, tag) {
  const res = await api('POST', `${QUESTION_BASE}/api/v1/tag`, {
    token,
    body: { name: tag.name, description: tag.description },
  });
  if (res.status === 409 || res.ok) return;
  warn(`tag ${tag.name} failed: ${res.status} ${JSON.stringify(res.body)}`);
}

async function askQuestion(token, q) {
  const res = await api('POST', `${QUESTION_BASE}/api/v1/question`, {
    token,
    body: { title: q.title, body: q.body, tagNames: q.tags },
  });
  if (!res.ok) {
    warn(`question "${q.title}" failed: ${res.status} ${JSON.stringify(res.body)}`);
    return null;
  }
  return unwrap(res).id;
}

async function postAnswer(token, questionId, body) {
  const res = await api('POST', `${ANSWER_BASE}/api/v1/answer`, { token, body: { questionId, body } });
  if (!res.ok) {
    warn(`answer on question ${questionId} failed: ${res.status} ${JSON.stringify(res.body)}`);
    return null;
  }
  return unwrap(res).id;
}

async function acceptAnswer(token, answerId) {
  const res = await api('PATCH', `${ANSWER_BASE}/api/v1/answer/${answerId}/accept`, { token });
  if (!res.ok && res.status !== 409) {
    warn(`accept answer ${answerId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

async function castVote(kind, token, id, direction) {
  const base = kind === 'question' ? QUESTION_BASE : ANSWER_BASE;
  const res = await api('PATCH', `${base}/api/v1/${kind}/${id}/${direction}`, { token });
  if (!res.ok && res.status !== 409) {
    warn(`${direction} on ${kind} ${id} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

async function recordView(sessions, questionId, view) {
  // IncrementViewsAsync only queues into Redis - real View rows are written later
  // by the background sync job, so there is nothing to wait for here.
  const res = await api('POST', `${QUESTION_BASE}/api/v1/view/${questionId}`, {
    token: view.by ? sessions[view.by] : undefined,
    headers: { 'X-Fingerprint': view.fingerprint },
  });
  if (!res.ok && res.status !== 204) {
    warn(`view on question ${questionId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

// ---------------------------------------------------------------- main

async function main() {
  log(`registering ${data.users.length} users`);
  const results = await Promise.all(data.users.map(registerUser));
  if (!RESEED && results.every((r) => r === 'exists')) {
    log('all seed users already exist - stack already seeded, nothing to do');
    return;
  }

  const sessions = {};
  const userIds = {};
  for (const u of data.users) {
    const token = await loginUser(u);
    userIds[u.username] = await initUser(token);
    sessions[u.username] = token;
  }
  log(`logged in ${data.users.length} users`);

  for (const username of data.adminUsernames) {
    await promoteToAdmin(username);
    // Re-login: the previous token was issued before the roles attribute changed.
    sessions[username] = await loginUser(data.users.find((u) => u.username === username));
  }
  log(`granted Admin to ${data.adminUsernames.join(', ')}`);

  log(`creating ${data.tags.length} tags`);
  for (const tag of data.tags) await ensureTag(sessions[data.adminUsernames[0]], tag);

  // Phase 1 - questions and answers. No reputation required for either.
  const posted = []; // { q, questionId, answers: [{ a, answerId }] }
  for (const q of data.questions) {
    const questionId = await askQuestion(sessions[q.askedBy], q);
    if (questionId == null) continue;
    const answers = [];
    for (const a of q.answers) {
      const answerId = await postAnswer(sessions[a.answeredBy], questionId, a.body);
      if (answerId != null) answers.push({ a, answerId });
    }
    posted.push({ q, questionId, answers });
  }
  const answerCount = posted.reduce((n, p) => n + p.answers.length, 0);
  log(`posted ${posted.length} questions and ${answerCount} answers`);

  // Phase 2 - accepts. The only reputation source available from a cold start.
  let accepted = 0;
  for (const { q, answers } of posted) {
    for (const { a, answerId } of answers) {
      if (!a.accepted) continue;
      await acceptAnswer(sessions[q.askedBy], answerId);
      accepted++;
    }
  }
  log(`accepted ${accepted} answers`);

  // Flatten the declared votes; who needs what reputation falls out of the data.
  const votes = [];
  for (const { q, questionId, answers } of posted) {
    for (const v of q.votes) votes.push({ kind: 'question', id: questionId, ...v });
    for (const { a, answerId } of answers) {
      for (const v of a.votes) votes.push({ kind: 'answer', id: answerId, ...v });
    }
  }
  const upvotes = votes.filter((v) => v.direction === 'upvote');
  const downvotes = votes.filter((v) => v.direction === 'downvote');

  const requirementsFor = (list, minimum) =>
    Object.fromEntries([...new Set(list.map((v) => v.by))].map((n) => [n, minimum]));

  // Phase 3 - upvotes, once the accept reputation has landed.
  await waitForReputation(requirementsFor(upvotes, MIN_REP_UPVOTE), userIds, 'upvoters');
  for (const v of upvotes) await castVote(v.kind, sessions[v.by], v.id, 'upvote');
  log(`cast ${upvotes.length} upvotes`);

  // Phase 4 - downvotes, once the upvote reputation has landed.
  await waitForReputation(requirementsFor(downvotes, MIN_REP_DOWNVOTE), userIds, 'downvoters');
  for (const v of downvotes) await castVote(v.kind, sessions[v.by], v.id, 'downvote');
  log(`cast ${downvotes.length} downvotes`);

  const viewCount = posted.reduce((n, p) => n + p.q.views.length, 0);
  for (const { q, questionId } of posted) {
    for (const view of q.views) await recordView(sessions, questionId, view);
  }
  log(`recorded ${viewCount} views`);

  const notifRes = await api('GET', `${NOTIFICATION_BASE}/api/v1/notification`, {
    token: sessions[data.users[0].username],
  });
  if (notifRes.ok) {
    const count = Array.isArray(notifRes.body?.data) ? notifRes.body.data.length : 'unknown';
    log(`notifications for ${data.users[0].username}: ${count}`);
  } else {
    warn(`could not verify notifications: ${notifRes.status}`);
  }

  const finalRep = readReputations();
  log('final reputation (earned entirely through the API):');
  for (const u of data.users) {
    const r = finalRep[userIds[u.username]] ?? 1;
    const tier = r >= MIN_REP_DOWNVOTE ? 'can upvote + downvote' : r >= MIN_REP_UPVOTE ? 'can upvote' : 'cannot vote';
    console.log(`         ${u.username.padEnd(8)} ${String(r).padStart(4)}   ${tier}`);
  }
  log(`done: ${data.users.length} users, ${data.tags.length} tags, ${posted.length} questions, ${answerCount} answers`);
}

main().catch((err) => {
  console.error('[seed] fatal:', err);
  process.exit(1);
});
