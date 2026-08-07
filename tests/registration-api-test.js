'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const testDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'ecosynq-api-test-'));
const registryFile = path.join(testDirectory, 'registry.json');
const signingKeyFile = path.join(testDirectory, 'signing-key.pem');
const apiToken = crypto.randomBytes(32).toString('hex');
const { privateKey } = crypto.generateKeyPairSync('ed25519');

fs.writeFileSync(
  signingKeyFile,
  privateKey.export({ type: 'pkcs8', format: 'pem' }),
  { mode: 0o600 }
);

process.env.REGISTRY_FILE = registryFile;
process.env.REGISTRATION_API_TOKEN = apiToken;
process.env.REGISTRATION_SIGNING_PRIVATE_KEY_FILE = signingKeyFile;

const { createServer } = require('../registration-api/app');

async function request(baseUrl, pathname, options = {}) {
  return fetch(`${baseUrl}${pathname}`, options);
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
    const authHeaders = {
      Authorization: `Bearer ${apiToken}`,
      'Content-Type': 'application/json'
    };

    let response = await request(baseUrl, '/healthz');
    assert.equal(response.status, 200);

    response = await request(baseUrl, '/api/nodes');
    assert.equal(response.status, 401);

    response = await request(baseUrl, '/api/public-key');
    assert.equal(response.status, 200);
    const publicKeyRecord = await response.json();
    assert.equal(publicKeyRecord.algorithm, 'Ed25519');

    const baseRegistration = {
      node_name: 'observation-vi-06143000z082026-a1b2',
      region: 'Virgin Islands (U.S.) (VI)',
      datacenter: 'hq',
      role: 'observation',
      vogon_id: 'b58:123456789ABCDEFGHJKLMNPQ'
    };

    response = await request(baseUrl, '/api/register-node', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ ...baseRegistration, role: 'administrator' })
    });
    assert.equal(response.status, 400);

    response = await request(baseUrl, '/api/register-node', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify(baseRegistration)
    });
    assert.equal(response.status, 200);
    const receipt = await response.json();
    assert.equal(receipt.node_name, baseRegistration.node_name);
    assert.equal(receipt.public_key_fingerprint, publicKeyRecord.fingerprint_sha256);

    const canonicalString = JSON.stringify(receipt.canonical);
    assert.equal(
      crypto.createHash('sha256').update(canonicalString).digest('hex'),
      receipt.hash
    );
    assert.equal(
      crypto.verify(
        null,
        Buffer.from(canonicalString),
        publicKeyRecord.public_key_pem,
        Buffer.from(receipt.signature, 'base64')
      ),
      true
    );

    response = await request(baseUrl, '/api/register-node', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify(baseRegistration)
    });
    assert.equal(response.status, 200);
    const duplicateReceipt = await response.json();
    assert.equal(duplicateReceipt.message, 'Already registered');
    assert.equal(duplicateReceipt.hash, receipt.hash);
    assert.deepEqual(duplicateReceipt.canonical, receipt.canonical);

    response = await request(baseUrl, '/api/register-node', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ ...baseRegistration, datacenter: 'conflicting-site' })
    });
    assert.equal(response.status, 409);

    response = await request(
      baseUrl,
      `/api/node/${encodeURIComponent(baseRegistration.node_name)}`,
      { headers: authHeaders }
    );
    assert.equal(response.status, 200);
    const lookupReceipt = await response.json();
    assert.deepEqual(lookupReceipt.canonical, receipt.canonical);

    response = await request(baseUrl, '/api/nodes', { headers: authHeaders });
    assert.equal(response.status, 200);
    const inventory = await response.json();
    assert.equal(inventory.count, 1);
    assert.equal(Object.hasOwn(inventory.nodes[0], 'vogon_id'), false);
    assert.equal(Object.hasOwn(inventory.nodes[0], 'canonical'), false);

    const cloudflareHeaders = { 'CF-Connecting-IP': '203.0.113.42' };
    for (let requestNumber = 1; requestNumber <= 60; requestNumber += 1) {
      response = await request(baseUrl, '/api/public-key', { headers: cloudflareHeaders });
      assert.equal(response.status, 200);
    }
    response = await request(baseUrl, '/api/public-key', { headers: cloudflareHeaders });
    assert.equal(response.status, 429);

    const onDiskRegistry = JSON.parse(fs.readFileSync(registryFile, 'utf8'));
    assert.equal(onDiskRegistry.version, '2.0');
    assert.equal(onDiskRegistry.nodes[baseRegistration.node_name].proof.algorithm, 'Ed25519');
    if (process.platform !== 'win32') {
      assert.equal((fs.statSync(registryFile).mode & 0o777), 0o600);
    }

    const appModulePath = require.resolve('../registration-api/app');
    delete require.cache[appModulePath];
    assert.doesNotThrow(() => require('../registration-api/app'));

    const tamperedRegistry = structuredClone(onDiskRegistry);
    tamperedRegistry.nodes[baseRegistration.node_name].role = 'causal-inference';
    fs.writeFileSync(registryFile, JSON.stringify(tamperedRegistry));
    delete require.cache[appModulePath];
    assert.throws(
      () => require('../registration-api/app'),
      /Registry proof verification failed/
    );

    console.log('Registration API runtime tests passed.');
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(testDirectory, { recursive: true, force: true });
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});