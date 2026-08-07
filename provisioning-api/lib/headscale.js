'use strict';

const { execFile } = require('node:child_process');

const HEADSCALE_BIN = process.env.HEADSCALE_BIN || 'headscale';
const HEADSCALE_ADOPTION_USER = process.env.HEADSCALE_ADOPTION_USER || '';
const HEADSCALE_CONFIG_PATH = process.env.HEADSCALE_CONFIG_PATH || '';

if (!HEADSCALE_ADOPTION_USER) {
  throw new Error('HEADSCALE_ADOPTION_USER is required (the Headscale user that owns adopted node tags)');
}

function configArgs() {
  return HEADSCALE_CONFIG_PATH ? ['--config', HEADSCALE_CONFIG_PATH] : [];
}

function run(args) {
  return new Promise((resolve, reject) => {
    execFile(HEADSCALE_BIN, [...configArgs(), ...args], { timeout: 20_000 }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(`headscale ${args.join(' ')} failed: ${stderr || error.message}`));
        return;
      }
      resolve(stdout);
    });
  });
}

let cachedUserId;

/**
 * `preauthkeys create --user` requires the numeric Headscale user ID, not the
 * username, so resolve and cache it once per process.
 */
async function resolveUserId() {
  if (cachedUserId !== undefined) {
    return cachedUserId;
  }
  const stdout = await run(['users', 'list', '--output', 'json']);
  const users = JSON.parse(stdout);
  const match = Array.isArray(users) && users.find((user) => user.name === HEADSCALE_ADOPTION_USER);
  if (!match) {
    throw new Error(`Headscale user '${HEADSCALE_ADOPTION_USER}' was not found`);
  }
  cachedUserId = String(match.id);
  return cachedUserId;
}

/**
 * Creates a single-use, short-lived, role-tagged Headscale pre-auth key.
 *
 * This shells out to the `headscale` CLI rather than the raw HTTP/gRPC API so
 * that connectivity relies on the already-documented remote-CLI setup
 * (HEADSCALE_CLI_ADDRESS / HEADSCALE_CLI_API_KEY, see headscale.net/stable/ref/api/#grpc),
 * which this process inherits from its environment/systemd unit.
 */
async function createPreAuthKey({ role, expirationSeconds }) {
  const userId = await resolveUserId();
  const expiration = `${Math.max(1, Math.floor(expirationSeconds || 3600))}s`;
  const stdout = await run([
    'preauthkeys',
    'create',
    '--user', userId,
    '--reusable=false',
    '--expiration', expiration,
    '--tags', `tag:${role}`,
    '--output', 'json'
  ]);

  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new Error('headscale preauthkeys create returned invalid JSON');
  }
  const key = parsed && (parsed.key || parsed.Key);
  if (!key) {
    throw new Error('headscale preauthkeys create returned no key');
  }
  return key;
}

/** Lightweight reachability check for a readiness probe. */
async function checkReachable() {
  try {
    await run(['nodes', 'list', '--output', 'json']);
    return true;
  } catch {
    return false;
  }
}

module.exports = { createPreAuthKey, checkReachable };
