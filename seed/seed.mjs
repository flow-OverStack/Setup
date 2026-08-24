#!/usr/bin/env node
// Seeds flow OverStack with mock data through the public REST APIs (not SQL),
// because QuestionService/AnswerService/NotificationService only know users by
// the id UserService assigns them - only the real registration path keeps ids
// consistent across services and fires the Kafka/outbox events NotificationService
// depends on. Bootstrap reference data (roles, vote types) is a separate, earlier
// step in setup.sh via lib/bootstrap-data.sh - this script assumes it already ran.
//
// Idempotent: registration 409s ("user already exists") on a second run and that
// is treated as "already seeded", so the whole run short-circuits.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const data = JSON.parse(readFileSync(join(__dirname, 'data.json'), 'utf-8'));

const USER_BASE = process.env.USER_SERVICE_URL ?? 'http://localhost:8085';
const QUESTION_BASE = process.env.QUESTION_SERVICE_URL ?? 'http://localhost:8087';
const ANSWER_BASE = process.env.ANSWER_SERVICE_URL ?? 'http://localhost:8089';
const NOTIFICATION_BASE = process.env.NOTIFICATION_SERVICE_URL ?? 'http://localhost:8091';

const RESEED = process.argv.includes('--reseed');

function log(msg) {
  console.log(`[seed] ${msg}`);
}
function warn(msg) {
  console.warn(`[seed] WARN: ${msg}`);
}

async function api(method, url, { token, body } = {}) {
  const headers = { 'content-type': 'application/json' };
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
  // seeder plays that role here so the local User row actually exists.
  const res = await api('POST', `${USER_BASE}/api/v1/auth/init`, { token });
  if (!res.ok && res.status !== 409) {
    warn(`init failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

async function promoteToAdmin(username) {
  // No API path can grant Admin on a fresh install (RoleController itself
  // requires Admin - see lib/bootstrap-data.sh for the full explanation), so
  // this reaches into Keycloak directly via the same admin token setup.sh
  // already validated.
  const adminToken = process.env.KC_ADMIN_TOKEN;
  const kcHost = process.env.KC_HOST ?? 'http://localhost:8080';
  const realm = 'flowOverStack';

  const tokenRes = await fetch(`${kcHost}/realms/${realm}/protocol/openid-connect/token`, {
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

  const findRes = await fetch(`${kcHost}/admin/realms/${realm}/users?username=${username}&exact=true`, {
    headers: { authorization: `Bearer ${kcToken}` },
  });
  const users = await findRes.json();
  const kcUser = users[0];
  if (!kcUser) throw new Error(`Keycloak user ${username} not found - register/login must run first`);

  const roles = new Set(kcUser.attributes?.roles ?? []);
  roles.add('Admin');

  const updateRes = await fetch(`${kcHost}/admin/realms/${realm}/users/${kcUser.id}`, {
    method: 'PUT',
    headers: { authorization: `Bearer ${kcToken}`, 'content-type': 'application/json' },
    body: JSON.stringify({ attributes: { ...kcUser.attributes, roles: [...roles] } }),
  });
  if (!updateRes.ok) throw new Error(`Failed to grant Admin to ${username}: ${updateRes.status}`);
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
  if (!res.ok && res.status !== 409 && res.status !== 403) {
    warn(`${direction} question ${questionId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

async function voteAnswer(token, answerId, direction) {
  const res = await api('PATCH', `${ANSWER_BASE}/api/v1/answer/${answerId}/${direction}`, { token });
  if (!res.ok && res.status !== 409 && res.status !== 403) {
    warn(`${direction} answer ${answerId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

async function acceptAnswer(token, answerId) {
  const res = await api('PATCH', `${ANSWER_BASE}/api/v1/answer/${answerId}/accept`, { token });
  if (!res.ok && res.status !== 409 && res.status !== 403) {
    warn(`accept answer ${answerId} failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
}

function pick(arr, n) {
  return arr.slice().sort(() => Math.random() - 0.5).slice(0, n);
}

async function main() {
  log(`registering ${data.users.length} users`);
  const results = await Promise.all(data.users.map(registerUser));

  if (!RESEED && results.every((r) => r === 'exists')) {
    log('all seed users already exist - stack already seeded, nothing to do');
    return;
  }

  const sessions = {};
  for (const u of data.users) {
    const token = await loginUser(u);
    await initUser(token.accessToken);
    sessions[u.username] = token.accessToken;
    log(`logged in ${u.username}`);
  }

  const adminUsername = data.adminUsername;
  log(`promoting ${adminUsername} to Admin via Keycloak`);
  await promoteToAdmin(adminUsername);
  // Fresh token needed - the old one was issued before the roles attribute changed.
  const adminUser = data.users.find((u) => u.username === adminUsername);
  const adminToken = (await loginUser(adminUser)).accessToken;
  sessions[adminUsername] = adminToken;

  log(`creating ${data.tags.length} tags`);
  for (const tag of data.tags) await ensureTag(adminToken, tag);

  const usernames = data.users.map((u) => u.username);
  const questionIds = [];
  log(`asking ${data.questions.length} questions`);
  for (const q of data.questions) {
    const asker = usernames[Math.floor(Math.random() * usernames.length)];
    const id = await askQuestion(sessions[asker], q);
    if (id != null) questionIds.push({ id, asker });
  }

  log('posting answers');
  let answerIndex = 0;
  const allAnswers = [];
  for (const { id: questionId, asker } of questionIds) {
    const answerCount = 1 + Math.floor(Math.random() * 3);
    const answerers = pick(
      usernames.filter((u) => u !== asker),
      answerCount,
    );
    for (const answerer of answerers) {
      const body = data.answers[answerIndex % data.answers.length];
      answerIndex++;
      const answerId = await postAnswer(sessions[answerer], questionId, body);
      if (answerId != null) allAnswers.push({ answerId, questionId, answerer, asker });
    }
  }

  log('casting votes and accepting answers');
  for (const { id: questionId, asker } of questionIds) {
    const voters = pick(
      usernames.filter((u) => u !== asker),
      2,
    );
    for (const voter of voters) {
      await voteQuestion(sessions[voter], questionId, Math.random() > 0.2 ? 'upvote' : 'downvote');
    }
  }
  for (const { answerId, asker, answerer } of allAnswers) {
    const voters = pick(
      usernames.filter((u) => u !== answerer),
      2,
    );
    for (const voter of voters) {
      await voteAnswer(sessions[voter], answerId, Math.random() > 0.2 ? 'upvote' : 'downvote');
    }
    if (Math.random() > 0.6) {
      await acceptAnswer(sessions[asker], answerId);
    }
  }

  log('verifying the Kafka -> notification path');
  const notifRes = await api('GET', `${NOTIFICATION_BASE}/api/v1/notification`, {
    token: sessions[usernames[0]],
  });
  if (notifRes.ok) {
    const count = Array.isArray(notifRes.body?.data) ? notifRes.body.data.length : 'unknown';
    log(`notifications for ${usernames[0]}: ${count}`);
  } else {
    warn(`could not verify notifications: ${notifRes.status}`);
  }

  log(`done: ${data.users.length} users, ${data.tags.length} tags, ${questionIds.length} questions, ${allAnswers.length} answers`);
}

main().catch((err) => {
  console.error('[seed] fatal:', err);
  process.exit(1);
});
