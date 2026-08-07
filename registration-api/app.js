const express = require('express');
const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');
const crypto = require('crypto');

process.umask(0o077);

const app = express();
const REGISTRY_FILE = process.env.REGISTRY_FILE || '/var/lib/ecosynq/node-registry.json';
const API_TOKEN_FILE = process.env.REGISTRATION_API_TOKEN_FILE || '';
if (API_TOKEN_FILE) {
  const tokenFileStats = fs.lstatSync(API_TOKEN_FILE);
  if (!tokenFileStats.isFile() || tokenFileStats.isSymbolicLink()) {
    throw new Error('Registration API token must be a regular file');
  }
  if (process.platform !== 'win32' && (tokenFileStats.mode & 0o077) !== 0) {
    throw new Error('Registration API token must not be group- or world-accessible');
  }
}
const API_TOKEN = process.env.REGISTRATION_API_TOKEN ||
  (API_TOKEN_FILE ? fs.readFileSync(API_TOKEN_FILE, 'utf8').trim() : '');
const SIGNING_KEY_FILE = process.env.REGISTRATION_SIGNING_PRIVATE_KEY_FILE || '';
const VALID_ROLES = new Set([
  'observation',
  'causal-inference',
  'independent-validation',
  'regional-qsa',
  'quantumvm',
  'q-topology',
  'surrealdb-projection',
  'immudb-evidence-authority',
  'checkout-registry'
]);

if (Buffer.byteLength(API_TOKEN) < 32) {
  throw new Error('REGISTRATION_API_TOKEN must contain at least 32 bytes');
}
if (!SIGNING_KEY_FILE) {
  throw new Error('REGISTRATION_SIGNING_PRIVATE_KEY_FILE is required');
}

const signingKeyStats = fs.lstatSync(SIGNING_KEY_FILE);
if (!signingKeyStats.isFile() || signingKeyStats.isSymbolicLink()) {
  throw new Error('Registration signing private key must be a regular file');
}
if (process.platform !== 'win32' && (signingKeyStats.mode & 0o077) !== 0) {
  throw new Error('Registration signing private key must not be group- or world-accessible');
}
const SIGNING_PRIVATE_KEY = crypto.createPrivateKey(fs.readFileSync(SIGNING_KEY_FILE));
if (SIGNING_PRIVATE_KEY.asymmetricKeyType !== 'ed25519') {
  throw new Error('Registration signing key must be Ed25519');
}
const SIGNING_PUBLIC_KEY = crypto.createPublicKey(SIGNING_PRIVATE_KEY);
const SIGNING_PUBLIC_KEY_PEM = SIGNING_PUBLIC_KEY.export({ type: 'spki', format: 'pem' });
const SIGNING_PUBLIC_KEY_FINGERPRINT = crypto
  .createHash('sha256')
  .update(SIGNING_PUBLIC_KEY.export({ type: 'spki', format: 'der' }))
  .digest('hex');

app.disable('x-powered-by');
app.use((_req, res, next) => {
  res.set({
    'Content-Security-Policy': "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=()'
  });
  next();
});
app.use(express.json({ limit: '16kb', strict: true }));
app.use(express.static(path.join(__dirname, 'public'), { dotfiles: 'deny', index: 'index.html' }));

function ensureRegistryDir() {
  const dir = path.dirname(REGISTRY_FILE);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  fs.chmodSync(dir, 0o700);
}

function loadRegistry() {
  ensureRegistryDir();
  if (!fs.existsSync(REGISTRY_FILE)) {
    const fresh = { version: '2.0', nodes: {} };
    saveRegistry(fresh);
    return fresh;
  }

  const registry = JSON.parse(fs.readFileSync(REGISTRY_FILE, 'utf8'));
  if (!registry || registry.version !== '2.0' || typeof registry.nodes !== 'object' || Array.isArray(registry.nodes)) {
    throw new Error('Registry schema is not signed version 2.0; archive and re-register legacy records');
  }
  for (const [nodeName, node] of Object.entries(registry.nodes)) {
    if (!isValidNodeName(nodeName) ||
      node.proof?.algorithm !== 'Ed25519' ||
      node.proof?.public_key_fingerprint !== SIGNING_PUBLIC_KEY_FINGERPRINT ||
      !node.proof?.hash ||
      !node.proof?.signature ||
      !node.canonical) {
      throw new Error(`Registry contains an unsigned or invalid record for ${nodeName}`);
    }
    const canonicalString = JSON.stringify(node.canonical);
    const metadataMatchesCanonical = nodeName === node.canonical.node_name &&
      node.region === node.canonical.region &&
      node.datacenter === node.canonical.datacenter &&
      node.role === node.canonical.role &&
      node.vogon_id === node.canonical.vogon_id &&
      node.timestamp === node.canonical.timestamp &&
      node.registered_at === node.canonical.timestamp;
    const expectedHash = crypto.createHash('sha256').update(canonicalString).digest('hex');
    const validSignature = crypto.verify(
      null,
      Buffer.from(canonicalString),
      SIGNING_PUBLIC_KEY,
      Buffer.from(node.proof.signature, 'base64')
    );
    if (!metadataMatchesCanonical || !secureEqual(node.proof.hash, expectedHash) || !validSignature) {
      throw new Error(`Registry proof verification failed for ${nodeName}`);
    }
  }
  return registry;
}

function saveRegistry(registry) {
  ensureRegistryDir();
  const tempFile = `${REGISTRY_FILE}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  let fileDescriptor;

  try {
    fileDescriptor = fs.openSync(tempFile, 'wx', 0o600);
    fs.writeFileSync(fileDescriptor, `${JSON.stringify(registry, null, 2)}\n`, 'utf8');
    fs.fsyncSync(fileDescriptor);
    fs.closeSync(fileDescriptor);
    fileDescriptor = undefined;
    fs.renameSync(tempFile, REGISTRY_FILE);
    fs.chmodSync(REGISTRY_FILE, 0o600);
    if (process.platform !== 'win32') {
      const directoryDescriptor = fs.openSync(path.dirname(REGISTRY_FILE), 'r');
      fs.fsyncSync(directoryDescriptor);
      fs.closeSync(directoryDescriptor);
    }
  } catch (error) {
    if (fileDescriptor !== undefined) {
      fs.closeSync(fileDescriptor);
    }
    fs.rmSync(tempFile, { force: true });
    throw error;
  }
}

function isValidVogonId(vogonId) {
  return typeof vogonId === 'string' && /^b58:[1-9A-HJ-NP-Za-km-z]{20,128}$/.test(vogonId);
}

function isValidNodeName(nodeName) {
  return typeof nodeName === 'string' &&
    nodeName.length <= 63 &&
    /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(nodeName);
}

function isValidMetadata(value, maxLength) {
  return typeof value === 'string' &&
    value.length > 0 &&
    value.length <= maxLength &&
    !/[<>\r\n\u0000-\u001f]/.test(value);
}

function secureEqual(left, right) {
  const leftDigest = crypto.createHash('sha256').update(left).digest();
  const rightDigest = crypto.createHash('sha256').update(right).digest();
  return crypto.timingSafeEqual(leftDigest, rightDigest);
}

function authenticateApi(req, res, next) {
  const authorization = req.get('authorization') || '';
  const prefix = 'Bearer ';
  if (!authorization.startsWith(prefix) || !secureEqual(authorization.slice(prefix.length), API_TOKEN)) {
    res.set('WWW-Authenticate', 'Bearer');
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

const rateBuckets = new Map();
const RATE_BUCKET_LIMIT = 4096;
let rateLimitRequests = 0;

function getRateLimitKey(req) {
  const remoteAddress = req.socket.remoteAddress || 'unknown';
  const cloudflareAddress = req.get('cf-connecting-ip') || '';
  const isLoopback = remoteAddress === '127.0.0.1' ||
    remoteAddress === '::1' ||
    remoteAddress === '::ffff:127.0.0.1';

  if (isLoopback && net.isIP(cloudflareAddress)) {
    return cloudflareAddress;
  }
  return remoteAddress;
}

function pruneRateBuckets(now) {
  for (const [key, bucket] of rateBuckets) {
    if (bucket.resetAt <= now) {
      rateBuckets.delete(key);
    }
  }

  while (rateBuckets.size >= RATE_BUCKET_LIMIT) {
    rateBuckets.delete(rateBuckets.keys().next().value);
  }
}

function rateLimitApi(req, res, next) {
  const now = Date.now();
  const windowMs = 60_000;
  const limit = 60;
  const key = getRateLimitKey(req);
  rateLimitRequests += 1;
  if (rateLimitRequests % 256 === 0 || rateBuckets.size >= RATE_BUCKET_LIMIT) {
    pruneRateBuckets(now);
  }
  const current = rateBuckets.get(key);
  const bucket = !current || current.resetAt <= now
    ? { count: 0, resetAt: now + windowMs }
    : current;
  bucket.count += 1;
  rateBuckets.set(key, bucket);

  if (bucket.count > limit) {
    res.set('Retry-After', String(Math.ceil((bucket.resetAt - now) / 1000)));
    return res.status(429).json({ error: 'Too many requests' });
  }
  next();
}

function createProof({ node_name, region, datacenter, role, vogon_id }) {
  const canonical = {
    version: '2.0',
    node_name,
    region,
    datacenter,
    role,
    vogon_id,
    timestamp: new Date().toISOString(),
    nonce: crypto.randomBytes(16).toString('hex')
  };

  const canonicalString = JSON.stringify(canonical);
  const proofHash = crypto.createHash('sha256').update(canonicalString).digest('hex');
  const proofSignature = crypto.sign(null, Buffer.from(canonicalString), SIGNING_PRIVATE_KEY).toString('base64');

  return { canonical, proofHash, proofSignature };
}

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
app.use('/api', rateLimitApi);
app.get('/api/public-key', (_req, res) => res.json({
  algorithm: 'Ed25519',
  fingerprint_sha256: SIGNING_PUBLIC_KEY_FINGERPRINT,
  public_key_pem: SIGNING_PUBLIC_KEY_PEM
}));
app.use('/api', authenticateApi);

app.post('/api/register-node', (req, res) => {
  const { node_name, region, datacenter, role, vogon_id } = req.body || {};

  if (!isValidNodeName(node_name)) {
    return res.status(400).json({ error: 'Invalid node_name' });
  }
  if (!isValidMetadata(region, 128) || !isValidMetadata(datacenter, 64)) {
    return res.status(400).json({ error: 'Invalid region or datacenter' });
  }
  if (!VALID_ROLES.has(role)) {
    return res.status(400).json({ error: 'Invalid node role' });
  }

  if (!isValidVogonId(vogon_id)) {
    return res.status(400).json({ error: 'Invalid VOGON ID format. Expected b58:<base58>' });
  }

  const registry = loadRegistry();
  const existing = registry.nodes[node_name];

  if (existing) {
    if (existing.vogon_id === vogon_id) {
      if (existing.region !== region || existing.datacenter !== datacenter || existing.role !== role) {
        return res.status(409).json({
          error: 'Node metadata conflicts with the signed existing registration.'
        });
      }

      return res.json({
        success: true,
        message: 'Already registered',
        hash: existing.proof.hash,
        signature: existing.proof.signature,
        public_key_fingerprint: existing.proof.public_key_fingerprint,
        canonical: existing.canonical,
        node_name,
        timestamp: existing.timestamp,
        registered_at: existing.registered_at
      });
    }

    return res.status(409).json({
      error: 'Node already registered to a different wallet. Contact support.'
    });
  }

  const { canonical, proofHash, proofSignature } = createProof({
    node_name,
    region,
    datacenter,
    role,
    vogon_id
  });

  registry.nodes[node_name] = {
    region,
    datacenter: datacenter || 'unknown',
    role,
    vogon_id,
    canonical,
    proof: {
      algorithm: 'Ed25519',
      hash: proofHash,
      signature: proofSignature,
      public_key_fingerprint: SIGNING_PUBLIC_KEY_FINGERPRINT
    },
    timestamp: canonical.timestamp,
    registered_at: canonical.timestamp
  };

  saveRegistry(registry);

  return res.json({
    success: true,
    hash: proofHash,
    signature: proofSignature,
    public_key_fingerprint: SIGNING_PUBLIC_KEY_FINGERPRINT,
    canonical,
    node_name,
    registered_at: registry.nodes[node_name].registered_at
  });
});

app.get('/api/node/:node_name', (req, res) => {
  if (!isValidNodeName(req.params.node_name)) {
    return res.status(400).json({ error: 'Invalid node_name' });
  }

  const registry = loadRegistry();
  const nodeName = req.params.node_name;
  const node = registry.nodes[nodeName];

  if (!node) {
    return res.status(404).json({ error: 'Node not found' });
  }

  return res.json({
    node_name: nodeName,
    region: node.region,
    role: node.role,
    vogon_id_prefix: `${node.vogon_id.substring(0, 12)}...`,
    registered_at: node.registered_at,
    hash: node.proof.hash,
    signature: node.proof.signature,
    public_key_fingerprint: node.proof.public_key_fingerprint,
    canonical: node.canonical
  });
});

app.get('/api/nodes', (_req, res) => {
  const registry = loadRegistry();
  const nodes = Object.entries(registry.nodes).map(([node_name, data]) => ({
    node_name,
    region: data.region,
    datacenter: data.datacenter,
    role: data.role,
    registered_at: data.registered_at,
    hash: data.proof.hash
  }));

  return res.json({
    count: nodes.length,
    nodes
  });
});

app.use((error, _req, res, _next) => {
  console.error('Registration API request failed:', error.message);
  if (error instanceof SyntaxError && error.status === 400) {
    return res.status(400).json({ error: 'Invalid JSON body' });
  }
  if (Number.isInteger(error.status) && error.status >= 400 && error.status < 500) {
    return res.status(error.status).json({ error: 'Invalid request' });
  }
  return res.status(500).json({ error: 'Internal server error' });
});

loadRegistry();

const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || '127.0.0.1';

function createServer() {
  const server = http.createServer(app);
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 50;
  return server;
}

if (require.main === module) {
  createServer().listen(port, host, () => {
    console.log(`EcoSynQ registration API listening on ${host}:${port}`);
  });
}

module.exports = { app, createServer };
