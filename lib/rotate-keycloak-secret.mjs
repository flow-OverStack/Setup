#!/usr/bin/env node
// Pushes a chosen client secret into a running Keycloak, authenticating with
// the OLD secret. Used by setup.sh when KC_ADMIN_TOKEN needs to change but the
// Keycloak instance already has the realm imported (so --import-realm alone
// won't touch it - Keycloak skips importing a realm that already exists).
//
// Usage: node rotate-keycloak-secret.mjs <kcHost> <oldSecret> <newSecret>
const [kcHost, oldSecret, newSecret] = process.argv.slice(2);
const realm = 'flowOverStack';
const clientId = 'user-service';

async function main() {
  const tokenRes = await fetch(`${kcHost}/realms/${realm}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: clientId, client_secret: oldSecret, grant_type: 'client_credentials' }),
  });
  if (!tokenRes.ok) {
    throw new Error(
      `Could not authenticate with the OLD KC_ADMIN_TOKEN (HTTP ${tokenRes.status}) - ` +
        `it no longer matches Keycloak, so the rotation can't proceed. ` +
        `If the secret is truly lost, the only way forward is 'teardown.sh --volumes' (wipes all data).`,
    );
  }
  const { access_token: adminToken } = await tokenRes.json();

  const findRes = await fetch(`${kcHost}/admin/realms/${realm}/clients?clientId=${clientId}`, {
    headers: { authorization: `Bearer ${adminToken}` },
  });
  const clients = await findRes.json();
  const client = clients[0];
  if (!client) throw new Error(`Client "${clientId}" not found in realm "${realm}"`);

  // PUT requires the full representation - a partial {secret: ...} body would
  // null out every other field Keycloak doesn't see in the payload.
  const getRes = await fetch(`${kcHost}/admin/realms/${realm}/clients/${client.id}`, {
    headers: { authorization: `Bearer ${adminToken}` },
  });
  const fullClient = await getRes.json();
  fullClient.secret = newSecret;

  const putRes = await fetch(`${kcHost}/admin/realms/${realm}/clients/${client.id}`, {
    method: 'PUT',
    headers: { authorization: `Bearer ${adminToken}`, 'content-type': 'application/json' },
    body: JSON.stringify(fullClient),
  });
  if (!putRes.ok) {
    throw new Error(`Failed to update the client secret (HTTP ${putRes.status}): ${await putRes.text()}`);
  }

  console.log('Rotated - user-service client secret now matches the new KC_ADMIN_TOKEN.');
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
