'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const SCRYPT_KEY_LENGTH = 64;

function ensureDir(filePath) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  fs.chmodSync(dir, 0o700);
}

function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const derived = crypto.scryptSync(password, salt, SCRYPT_KEY_LENGTH);
  return { algorithm: 'scrypt', salt: salt.toString('hex'), hash: derived.toString('hex') };
}

function verifyPassword(password, record) {
  if (!record || record.algorithm !== 'scrypt' || !record.salt || !record.hash) {
    return false;
  }
  const salt = Buffer.from(record.salt, 'hex');
  const expected = Buffer.from(record.hash, 'hex');
  const actual = crypto.scryptSync(password, salt, SCRYPT_KEY_LENGTH);
  if (actual.length !== expected.length) {
    return false;
  }
  return crypto.timingSafeEqual(actual, expected);
}

class UserStore {
  constructor(usersFile) {
    this.usersFile = usersFile;
  }

  load() {
    ensureDir(this.usersFile);
    if (!fs.existsSync(this.usersFile)) {
      const fresh = { version: '1.0', users: {} };
      this.save(fresh);
      return fresh;
    }
    const store = JSON.parse(fs.readFileSync(this.usersFile, 'utf8'));
    if (!store || store.version !== '1.0' || typeof store.users !== 'object' || Array.isArray(store.users)) {
      throw new Error('Users store schema is not recognized version 1.0');
    }
    return store;
  }

  save(store) {
    ensureDir(this.usersFile);
    const tempFile = `${this.usersFile}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
    let fileDescriptor;
    try {
      fileDescriptor = fs.openSync(tempFile, 'wx', 0o600);
      fs.writeFileSync(fileDescriptor, `${JSON.stringify(store, null, 2)}\n`, 'utf8');
      fs.fsyncSync(fileDescriptor);
      fs.closeSync(fileDescriptor);
      fileDescriptor = undefined;
      fs.renameSync(tempFile, this.usersFile);
      fs.chmodSync(this.usersFile, 0o600);
    } catch (error) {
      if (fileDescriptor !== undefined) {
        fs.closeSync(fileDescriptor);
      }
      fs.rmSync(tempFile, { force: true });
      throw error;
    }
  }

  upsertUser(username, password, { expiresAt } = {}) {
    const store = this.load();
    store.users[username] = {
      ...hashPassword(password),
      created_at: new Date().toISOString(),
      expires_at: expiresAt || null
    };
    this.save(store);
  }

  removeUser(username) {
    const store = this.load();
    delete store.users[username];
    this.save(store);
  }

  /** Returns { username } on success, or null on any failure (unknown user, bad password, expired). */
  authenticate(username, password) {
    if (typeof username !== 'string' || typeof password !== 'string' || !username || !password) {
      return null;
    }
    const store = this.load();
    const record = store.users[username];
    if (!record) {
      return null;
    }
    if (record.expires_at && Date.parse(record.expires_at) <= Date.now()) {
      return null;
    }
    if (!verifyPassword(password, record)) {
      return null;
    }
    return { username };
  }
}

module.exports = { UserStore, hashPassword, verifyPassword };
