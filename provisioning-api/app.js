'use strict';

const express = require('express');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');

const { createAuthenticator } = require('./lib/auth');
const { SessionManager, serializeCookie, clearedCookie } = require('./lib/session');
const { BootstrapTokenStore } = require('./lib/bootstrap-tokens');
const headscale = require('./lib/headscale');

process.umask(0o077);

const VALID_ROLES = [
  'observation',
  'causal-inference',
  'independent-validation',
  'regional-qsa',
  'quantumvm',
  'q-topology',
  'surrealdb-projection',
  'immudb-evidence-authority',
  'checkout-registry'
];
const VALID_ROLE_SET = new Set(VALID_ROLES);
const REGIONS = JSON.parse(fs.readFileSync(path.join(__dirname, 'lib', 'regions.json'), 'utf8'));
const REGION_SET = new Set(REGIONS);

const USERS_FILE = process.env.USERS_FILE || '/var/lib/ecosynq/provisioning-users.json';
const BOOTSTRAP_TOKENS_FILE = process.env.BOOTSTRAP_TOKENS_FILE || '/var/lib/ecosynq/bootstrap-tokens.json';
const SESSION_SECRET_FILE = process.env.SESSION_SECRET_FILE || '';
const HEADSCALE_URL = process.env.HEADSCALE_URL || '';
const PORTAL_BASE_URL = process.env.PORTAL_BASE_URL || '';
const INSTALL_SCRIPT_PATH = process.env.INSTALL_SCRIPT_PATH || path.join(__dirname, '..', 'eco-node-adopt.sh');
const BOOTSTRAP_TOKEN_TTL_SECONDS = Number(process.env.BOOTSTRAP_TOKEN_TTL_SECONDS || 900);
const SESSION_TTL_SECONDS = Number(process.env.SESSION_TTL_SECONDS || 1800);

if (!SESSION_SECRET_FILE) {
  throw new Error('SESSION_SECRET_FILE is required');
}
const sessionSecretStats = fs.lstatSync(SESSION_SECRET_FILE);
if (!sessionSecretStats.isFile() || sessionSecretStats.isSymbolicLink()) {
  throw new Error('Session secret must be a regular file');
}
if (process.platform !== 'win32' && (sessionSecretStats.mode & 0o077) !== 0) {
  throw new Error('Session secret file must not be group- or world-accessible');
}
const SESSION_SECRET = fs.readFileSync(SESSION_SECRET_FILE, 'utf8').trim();

if (!HEADSCALE_URL || !/^https:\/\//.test(HEADSCALE_URL)) {
  throw new Error('HEADSCALE_URL must be set and use HTTPS');
}
if (!PORTAL_BASE_URL || !/^https:\/\//.test(PORTAL_BASE_URL)) {
  throw new Error('PORTAL_BASE_URL must be set and use HTTPS');
}
if (!fs.existsSync(INSTALL_SCRIPT_PATH)) {
  throw new Error(`INSTALL_SCRIPT_PATH does not exist: ${INSTALL_SCRIPT_PATH}`);
}

const auth = createAuthenticator(USERS_FILE);
const sessions = new SessionManager(SESSION_SECRET, { ttlSeconds: SESSION_TTL_SECONDS });
const bootstrapTokens = new BootstrapTokenStore(BOOTSTRAP_TOKENS_FILE);

const app = express();
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
app.use(express.json({ limit: '8kb', strict: true }));
app.use(express.static(path.join(__dirname, 'public'), { dotfiles: 'deny', index: 'login.html' }));

const rateBuckets = new Map();
const RATE_BUCKET_LIMIT = 4096;
let rateLimitRequests = 0;

function getRateLimitKey(req) {
  const remoteAddress = req.socket.remoteAddress || 'unknown';
  const cloudflareAddress = req.get('cf-connecting-ip') || '';
  const isLoopback = remoteAddress === '127.0.0.1' || remoteAddress === '::1' || remoteAddress === '::ffff:127.0.0.1';
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

function rateLimit(limit, windowMs) {
  return (req, res, next) => {
    const now = Date.now();
    const key = `${limit}:${windowMs}:${getRateLimitKey(req)}`;
    rateLimitRequests += 1;
    if (rateLimitRequests % 256 === 0 || rateBuckets.size >= RATE_BUCKET_LIMIT) {
      pruneRateBuckets(now);
    }
    const current = rateBuckets.get(key);
    const bucket = !current || current.resetAt <= now ? { count: 0, resetAt: now + windowMs } : current;
    bucket.count += 1;
    rateBuckets.set(key, bucket);
    if (bucket.count > limit) {
      res.set('Retry-After', String(Math.ceil((bucket.resetAt - now) / 1000)));
      return res.status(429).json({ error: 'Too many requests' });
    }
    next();
  };
}

function requireSession(req, res, next) {
  const user = sessions.readUser(req);
  if (!user) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  req.user = user;
  next();
}

function extractRegionCode(region) {
  const match = /\(([A-Za-z]{2})\)\s*$/.exec(region || '');
  return match ? match[1].toUpperCase() : null;
}

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
app.get('/readyz', async (_req, res) => {
  const reachable = await headscale.checkReachable();
  res.status(reachable ? 200 : 503).json({ headscale_reachable: reachable });
});

app.post('/api/auth/login', rateLimit(10, 60_000), (req, res) => {
  const { username, password } = req.body || {};
  const result = auth.authenticate(username, password);
  if (!result) {
    return res.status(401).json({ error: 'Invalid username or password' });
  }
  const cookie = sessions.createCookie(result.username);
  res.set('Set-Cookie', serializeCookie(cookie));
  return res.json({ success: true, username: result.username });
});

app.post('/api/auth/logout', (_req, res) => {
  res.set('Set-Cookie', clearedCookie());
  return res.json({ success: true });
});

app.get('/api/session', requireSession, (req, res) => res.json({ username: req.user.username }));

app.get('/api/catalog', requireSession, (_req, res) => res.json({ roles: VALID_ROLES, regions: REGIONS }));

app.post('/api/bootstrap', requireSession, rateLimit(20, 60_000), (req, res) => {
  const { role, region } = req.body || {};
  if (!VALID_ROLE_SET.has(role)) {
    return res.status(400).json({ error: 'Invalid role' });
  }
  if (!REGION_SET.has(region)) {
    return res.status(400).json({ error: 'Invalid region' });
  }
  const regionCode = extractRegionCode(region);
  if (!regionCode) {
    return res.status(400).json({ error: 'Region is missing a two-letter code' });
  }

  const { token, expiresAt } = bootstrapTokens.create({
    role,
    region,
    regionCode,
    datacenter: 'hq',
    createdBy: req.user.username,
    ttlSeconds: BOOTSTRAP_TOKEN_TTL_SECONDS
  });

  const curlCommand = [
    `curl -fsSL ${PORTAL_BASE_URL}/install.sh |`,
    'sudo env',
    `HEADSCALE_URL="${HEADSCALE_URL}"`,
    `PROVISIONING_API_URL="${PORTAL_BASE_URL}"`,
    `PROVISIONING_API_TOKEN="${token}"`,
    `NODE_ROLE="${role}"`,
    `NODE_REGION="${region}"`,
    `NODE_REGION_CODE="${regionCode}"`,
    'bash'
  ].join(' ');

  return res.json({ curl_command: curlCommand, token, expires_at: new Date(expiresAt).toISOString(), role, region });
});

app.post('/api/key/generate', rateLimit(30, 60_000), async (req, res) => {
  const authorization = req.get('authorization') || '';
  const prefix = 'Bearer ';
  if (!authorization.startsWith(prefix)) {
    res.set('WWW-Authenticate', 'Bearer');
    return res.status(401).json({ error: 'Unauthorized' });
  }
  const token = authorization.slice(prefix.length);
  const claimed = bootstrapTokens.claim(token);
  if (!claimed) {
    return res.status(401).json({ error: 'Bootstrap token is invalid, expired, or already used' });
  }

  const { node_role: nodeRole, node_region_code: nodeRegionCode } = req.body || {};
  if (nodeRole !== claimed.role || (nodeRegionCode || '').toUpperCase() !== claimed.region_code) {
    bootstrapTokens.release(claimed.key);
    return res.status(400).json({ error: 'Requested role/region does not match the issued bootstrap token' });
  }

  try {
    const preAuthKey = await headscale.createPreAuthKey({ role: claimed.role, expirationSeconds: 3600 });
    return res.json({ pre_auth_key: preAuthKey });
  } catch (error) {
    bootstrapTokens.release(claimed.key);
    console.error('Headscale pre-auth key issuance failed:', error.message);
    return res.status(502).json({ error: 'Failed to issue a pre-auth key' });
  }
});

app.get('/install.sh', (_req, res) => {
  res.set('Content-Type', 'text/x-shellscript; charset=utf-8');
  res.send(fs.readFileSync(INSTALL_SCRIPT_PATH, 'utf8'));
});

app.use((error, _req, res, _next) => {
  console.error('Provisioning API request failed:', error.message);
  if (error instanceof SyntaxError && error.status === 400) {
    return res.status(400).json({ error: 'Invalid JSON body' });
  }
  if (Number.isInteger(error.status) && error.status >= 400 && error.status < 500) {
    return res.status(error.status).json({ error: 'Invalid request' });
  }
  return res.status(500).json({ error: 'Internal server error' });
});

const port = Number(process.env.PORT || 8080);
const host = process.env.HOST || '127.0.0.1';

function createServer() {
  const server = http.createServer(app);
  server.requestTimeout = 20_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 50;
  return server;
}

if (require.main === module) {
  createServer().listen(port, host, () => {
    console.log(`EcoSynQ provisioning API listening on ${host}:${port}`);
  });
}

module.exports = { app, createServer };
