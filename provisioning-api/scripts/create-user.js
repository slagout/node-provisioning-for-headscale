#!/usr/bin/env node
'use strict';

/**
 * Admin CLI to add or rotate a portal user's temporary password.
 *
 * Usage:
 *   USERS_FILE=/var/lib/ecosynq/provisioning-users.json \
 *     node scripts/create-user.js <username> [--expires-in-hours 24]
 *
 * Prints a randomly generated temporary password once. It is never stored or logged.
 */

const crypto = require('node:crypto');
const path = require('node:path');
const { UserStore } = require('../lib/users');

function parseArgs(argv) {
  const [username, ...rest] = argv;
  let expiresInHours = null;
  for (let i = 0; i < rest.length; i += 1) {
    if (rest[i] === '--expires-in-hours') {
      expiresInHours = Number(rest[i + 1]);
      i += 1;
    }
  }
  return { username, expiresInHours };
}

function main() {
  const { username, expiresInHours } = parseArgs(process.argv.slice(2));
  if (!username || !/^[a-z0-9._-]{2,64}$/i.test(username)) {
    console.error('Usage: node scripts/create-user.js <username> [--expires-in-hours 24]');
    process.exitCode = 1;
    return;
  }

  const usersFile = process.env.USERS_FILE || path.join('/var/lib/ecosynq', 'provisioning-users.json');
  const tempPassword = crypto.randomBytes(12).toString('base64url');
  const expiresAt = expiresInHours ? new Date(Date.now() + expiresInHours * 3600_000).toISOString() : null;

  const store = new UserStore(usersFile);
  store.upsertUser(username, tempPassword, { expiresAt });

  console.log(`User '${username}' created/updated in ${usersFile}`);
  console.log(`Temporary password (shown once): ${tempPassword}`);
  if (expiresAt) {
    console.log(`Expires at: ${expiresAt}`);
  }
}

main();
