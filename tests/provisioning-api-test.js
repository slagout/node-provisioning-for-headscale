'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const testDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'ecosynq-provisioning-test-'));
const usersFile = path.join(testDirectory, 'users.json');
const bootstrapTokensFile = path.join(testDirectory, 'bootstrap-tokens.json');
const sessionSecretFile = path.join(testDirectory, 'session-secret');
const fakeHeadscaleBin = path.join(testDirectory, 'fake-headscale.sh');
const installScriptPath = path.join(testDirectory, 'install.sh');

fs.writeFileSync(sessionSecretFile, crypto.randomBytes(32).toString('hex'), { mode: 0o600 });
fs.writeFileSync(
  fakeHeadscaleBin,
  [
    '#!/usr/bin/env bash',
    'if [[ "$*" == *"users list"* ]]; then',
    '  echo \'[{"id":1,"name":"provisioner"}]\'',
    'else',
    '  echo \'{"key":"fake-preauth-key-1234"}\'',
    'fi',
    ''
  ].join('\n'),
  { mode: 0o755 }
);
fs.writeFileSync(installScriptPath, '#!/usr/bin/env bash\necho "fake adopt script"\n', { mode: 0o755 });

process.env.USERS_FILE = usersFile;
process.env.BOOTSTRAP_TOKENS_FILE = bootstrapTokensFile;
process.env.SESSION_SECRET_FILE = sessionSecretFile;
process.env.HEADSCALE_URL = 'https://headscale.example.test';
process.env.PORTAL_BASE_URL = 'https://provisioning.example.test';
process.env.INSTALL_SCRIPT_PATH = installScriptPath;
process.env.HEADSCALE_ADOPTION_USER = 'provisioner';
process.env.HEADSCALE_BIN = fakeHeadscaleBin;
process.env.BOOTSTRAP_TOKEN_TTL_SECONDS = '900';

const { UserStore } = require('../provisioning-api/lib/users');
const { createServer } = require('../provisioning-api/app');

const TEST_USERNAME = 'jdoe';
const TEST_PASSWORD = 'correct-horse-battery-staple';
new UserStore(usersFile).upsertUser(TEST_USERNAME, TEST_PASSWORD);

function extractCookie(response) {
  const setCookie = response.headers.get('set-cookie') || '';
  return setCookie.split(';')[0];
}

async function run() {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await new Promise((resolve, reject) => {
    server.once('listening', resolve);
    server.once('error', reject);
  });

  try {
    const address = server.address();
    const baseUrl = `http://127.0.0.1:${address.port}`;

    let response = await fetch(`${baseUrl}/healthz`);
    assert.equal(response.status, 200);

    response = await fetch(`${baseUrl}/api/session`);
    assert.equal(response.status, 401);

    response = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: TEST_USERNAME, password: 'wrong-password' })
    });
    assert.equal(response.status, 401);

    response = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: TEST_USERNAME, password: TEST_PASSWORD })
    });
    assert.equal(response.status, 200);
    const cookie = extractCookie(response);
    assert.ok(cookie.startsWith('ecosynq_session='));

    response = await fetch(`${baseUrl}/api/session`, { headers: { Cookie: cookie } });
    assert.equal(response.status, 200);
    const sessionBody = await response.json();
    assert.equal(sessionBody.username, TEST_USERNAME);

    response = await fetch(`${baseUrl}/api/catalog`, { headers: { Cookie: cookie } });
    assert.equal(response.status, 200);
    const catalog = await response.json();
    assert.ok(catalog.roles.includes('observation'));
    assert.ok(catalog.regions.includes('Virgin Islands (U.S.) (VI)'));

    response = await fetch(`${baseUrl}/api/bootstrap`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Cookie: cookie },
      body: JSON.stringify({ role: 'observation', region: 'Virgin Islands (U.S.) (VI)' })
    });
    assert.equal(response.status, 200);
    const bootstrap = await response.json();
    assert.ok(bootstrap.token);
    assert.match(bootstrap.curl_command, /NODE_REGION_CODE="VI"/);
    assert.match(bootstrap.curl_command, new RegExp(`PROVISIONING_API_TOKEN="${bootstrap.token}"`));

    // Mismatched role/region is rejected and does not burn the one-time token.
    response = await fetch(`${baseUrl}/api/key/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${bootstrap.token}` },
      body: JSON.stringify({ node_role: 'causal-inference', node_region_code: 'VI' })
    });
    assert.equal(response.status, 400);

    response = await fetch(`${baseUrl}/api/key/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${bootstrap.token}` },
      body: JSON.stringify({ node_role: 'observation', node_region_code: 'vi' })
    });
    assert.equal(response.status, 200);
    const keyResponse = await response.json();
    assert.equal(keyResponse.pre_auth_key, 'fake-preauth-key-1234');

    // Token is single-use: a second redemption must fail.
    response = await fetch(`${baseUrl}/api/key/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${bootstrap.token}` },
      body: JSON.stringify({ node_role: 'observation', node_region_code: 'VI' })
    });
    assert.equal(response.status, 401);

    response = await fetch(`${baseUrl}/api/key/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer not-a-real-token' },
      body: JSON.stringify({ node_role: 'observation', node_region_code: 'VI' })
    });
    assert.equal(response.status, 401);

    response = await fetch(`${baseUrl}/install.sh`);
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type') || '', /text\/x-shellscript/);
    const installBody = await response.text();
    assert.match(installBody, /fake adopt script/);

    response = await fetch(`${baseUrl}/api/auth/logout`, { method: 'POST' });
    assert.equal(response.status, 200);

    response = await fetch(`${baseUrl}/api/session`, { headers: { Cookie: cookie } });
    assert.equal(response.status, 200, 'logout only clears the caller cookie jar, not other holders of the same signed cookie');

    console.log('Provisioning API tests passed.');
  } finally {
    server.close();
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
