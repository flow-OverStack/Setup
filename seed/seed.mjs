#!/usr/bin/env node
// Seeds flow OverStack with mock data through the public REST APIs (not SQL),
// because QuestionService/AnswerService/NotificationService only know users by
// the id UserService assigns them - only the real registration path keeps ids
// consistent across services and fires the Kafka/outbox events NotificationService
// depends on. Bootstrap reference data (roles, vote types, reputation rules) is a
// separate, earlier step in setup.sh via lib/bootstrap-data.sh - this script
// assumes it already ran.
//
// The one exception is reputation: there is no public API that can create a
// ReputationRecord (it's purely an internal side effect of vote/accept events),
// and it needs real User.Id values that don't exist until after registration -
// so it can't live in the early bootstrap phase either. This script inserts it
// directly via psql, once per user, right after registration.
//
// Idempotent: registration 409s ("user already exists") on a second run and that
// is treated as "already seeded", so the whole run short-circuits.

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

const RESEED = process.argv.includes('--reseed');

function log(msg) {
  console.log(`[seed] ${msg}`);
}
function warn(msg) {
  console.warn(`[seed] WARN: ${msg}`);
}

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
    // empty body is fine
  }
  return { status: res.status, ok: res.ok, body: json };
}

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
  return res.body.data ?? res.body; // BaseResult<TokenDto> wraps in .data
}

async function initUser(token) {
  // Must be called once after registration - the frontend's job normally, the
  // seeder plays that role here. Idempotent: UserProvisioningService.InitAsync
  // returns the existing UserDto (with its real numeric Id) on every call once
  // the local row exists, so this also doubles as "how do I get this user's id".
  const res = await api('POST', `${USER_BASE}/api/v1/auth/init`, { token });
  if (!res.ok) throw new Error(`init failed: ${res.status} ${JSON.stringify(res.body)}`);
  return (res.body.data ?? res.body).id;
}

async function promoteToAdmin(username) {
  // No API path can grant Admin on a fresh install (RoleController itself
  // requires Admin - see lib/bootstrap-data.sh for the full explanation), so
  // this reaches into Keycloak directly via the same admin token setup.sh
  // already validated.
  const adminToken = process.env.KC_ADMIN_TOKEN;
  const realm = 'flowOverStack';

  const tokenRes = await fetch(`${KC_HOST}/realms/${realm}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: 'user-service',
      client_secret: adminToken,
      grant_type: 'client_credentials',
    }),
  });
  if (!tokenRes.ok) throw new Error(`Keycloak client_credentials token fetch failed: ${tokenRes.status}`);
  const { access_token: kcToken } = await tokenRes.json();

  const findRes = await fetch(`${KC_HOST}/admin/realms/${realm}/users?username=${username}&exact=true`, {
    headers: { authorization: `Bearer ${kcToken}` },
  });
  const users = await findRes.json();
  const kcUser = users[0];
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

// Seeds reputation the same way the app itself would arrive at it - by creating
// ReputationRecord rows against the real EntityUpvoted/Question/Author rule
// (+10 each, see lib/bootstrap-data.sh) - just directly via SQL, since no public
// API can create one. All rows share a single CreatedAt (`now()`, one value per
// SQL statement) on purpose: GetUserService.GetCurrentReputationsAsync groups
// ReputationRecords by (UserId, Date) and the gRPC layer calls .Single() on a
// single-user lookup - records spread across more than one calendar date would
// throw. Skips a user entirely if they already have any records, so `--reseed`
// doesn't stack multiples on top of what a prior run created.
function seedReputation(userId, upvoteCount) {
  if (upvoteCount <= 0) return; // no records -> falls back to the app's own MinReputation default
  if (!Number.isInteger(userId) || !Number.isInteger(upvoteCount)) {
    throw new Error(`seedReputation: expected integers, got userId=${userId} upvoteCount=${upvoteCount}`);
  }
  const sql = `
DO $$
DECLARE
  rule_id bigint;
  existing_count int;
BEGIN
  SELECT COUNT(*) INTO existing_count FROM "ReputationRecord" WHERE "ReputationTargetId" = ${userId};
  IF existing_count > 0 THEN
    RETURN;
  END IF;

  SELECT "Id" INTO rule_id FROM "ReputationRule"
    WHERE "EventType" = 'EntityUpvoted' AND "EntityType" = 'Question'
      AND "ReputationTarget" = 0 AND "Group" = 'Vote';

  INSERT INTO "ReputationRecord" ("ReputationTargetId", "InitiatorId", "ReputationRuleId", "EntityId", "Enabled", "CreatedAt")
  SELECT ${userId}, ${userId}, rule_id, 900000 + n, true, now()
  FROM generate_series(1, ${upvoteCount}) AS n;
END $$;
`;
  execFileSync('docker', ['exec', '-i', 'postgres-user-db', 'psql', '-U', 'postgres', '-d', 'user-service-db', '-v', 'ON_ERROR_STOP=1', '-q'], {
    input: sql,
    stdio: ['pipe', 'inherit', 'inherit'],
  });
}

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
  return (res.body.data ?? res.body).id;
}

async function postAnswer(token, questionId, body) {
  const res = await api('POST', `${ANSWER_BASE}/api/v1/answer`, {
    token,
    body: { questionId, body },
  });
  if (!res.ok) {
    warn(`answer on question ${questionId} failed: ${res.status} ${JSON.stringify(res.body)}`);
    return null;
  }
  return (res.body.data ?? res.body).id;
}

async function voteQuestion(token, questionId, direction) {
  const res = await api('PATCH', `${QUESTION_BASE}/api/v1/question/${questionId}/${direction}`, { token });
  if (!res.ok && res.status !== 409) {
    warn(`${direction} question ${questionId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

async function voteAnswer(token, answerId, direction) {
  const res = await api('PATCH', `${ANSWER_BASE}/api/v1/answer/${answerId}/${direction}`, { token });
  if (!res.ok && res.status !== 409) {
    warn(`${direction} answer ${answerId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

async function acceptAnswer(token, answerId) {
  const res = await api('PATCH', `${ANSWER_BASE}/api/v1/answer/${answerId}/accept`, { token });
  if (!res.ok && res.status !== 409) {
    warn(`accept answer ${answerId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

async function recordView(questionId, view) {
  // Fire-and-forget by design: IncrementViewsAsync only queues into Redis - the
  // actual View rows land later via a background sync job, not synchronously.
  const headers = { 'X-Fingerprint': view.fingerprint };
  const token = view.by ? sessions[view.by] : undefined;
  const res = await api('POST', `${QUESTION_BASE}/api/v1/view/${questionId}`, { token, headers });
  if (!res.ok && res.status !== 204) {
    warn(`view on question ${questionId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

const sessions = {};

async function main() {
  log(`registering ${data.users.length} users`);
  const results = await Promise.all(data.users.map(registerUser));

  if (!RESEED && results.every((r) => r === 'exists')) {
    log('all seed users already exist - stack already seeded, nothing to do');
    return;
  }

  const userIds = {};
  for (const u of data.users) {
    const token = (await loginUser(u)).accessToken;
    const id = await initUser(token);
    sessions[u.username] = token;
    userIds[u.username] = id;
    log(`logged in ${u.username} (id ${id})`);
  }

  log('seeding reputation records');
  for (const u of data.users) {
    seedReputation(userIds[u.username], u.reputationUpvotes);
  }

  for (const adminUsername of data.adminUsernames) {
    log(`promoting ${adminUsername} to Admin via Keycloak`);
    await promoteToAdmin(adminUsername);
    // Fresh token needed - the old one was issued before the roles attribute changed.
    const adminUser = data.users.find((u) => u.username === adminUsername);
    sessions[adminUsername] = (await loginUser(adminUser)).accessToken;
  }
  const primaryAdminToken = sessions[data.adminUsernames[0]];

  log(`creating ${data.tags.length} tags`);
  for (const tag of data.tags) await ensureTag(primaryAdminToken, tag);

  log(`asking ${data.questions.length} questions and their answers`);
  for (const q of data.questions) {
    const questionId = await askQuestion(sessions[q.askedBy], q);
    if (questionId == null) continue;

    for (const v of q.votes) await voteQuestion(sessions[v.by], questionId, v.direction);
    for (const v of q.views) await recordView(questionId, v);

    for (const a of q.answers) {
      const answerId = await postAnswer(sessions[a.answeredBy], questionId, a.body);
      if (answerId == null) continue;

      for (const v of a.votes) await voteAnswer(sessions[v.by], answerId, v.direction);
      if (a.accepted) await acceptAnswer(sessions[q.askedBy], answerId);
    }
  }

  log('verifying the Kafka -> notification path');
  const notifRes = await api('GET', `${NOTIFICATION_BASE}/api/v1/notification`, {
    token: sessions[data.users[0].username],
  });
  if (notifRes.ok) {
    const count = Array.isArray(notifRes.body?.data) ? notifRes.body.data.length : 'unknown';
    log(`notifications for ${data.users[0].username}: ${count}`);
  } else {
    warn(`could not verify notifications: ${notifRes.status}`);
  }

  const answerCount = data.questions.reduce((n, q) => n + q.answers.length, 0);
  log(`done: ${data.users.length} users, ${data.tags.length} tags, ${data.questions.length} questions, ${answerCount} answers`);
}

main().catch((err) => {
  console.error('[seed] fatal:', err);
  process.exit(1);
});
