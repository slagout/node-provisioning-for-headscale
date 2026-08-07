'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function ensureDir(filePath) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  fs.chmodSync(dir, 0o700);
}

function hashToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

/**
 * One-time bootstrap tokens bridge the login portal and the existing
 * PROVISIONING_API_TOKEN contract in eco-node-adopt.sh. Each token is scoped
 * to a single role/region choice, usable exactly once, and expires quickly.
 */
class BootstrapTokenStore {
  constructor(storeFile) {
    this.storeFile = storeFile;
    this.records = new Map();
    this.load();
  }

  load() {
    ensureDir(this.storeFile);
    if (!fs.existsSync(this.storeFile)) {
      this.persist();
      return;
    }
    const parsed = JSON.parse(fs.readFileSync(this.storeFile, 'utf8'));
    if (parsed && typeof parsed.tokens === 'object' && !Array.isArray(parsed.tokens)) {
      this.records = new Map(Object.entries(parsed.tokens));
    }
    this.pruneExpired();
  }

  persist() {
    ensureDir(this.storeFile);
    const tempFile = `${this.storeFile}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
    const payload = { version: '1.0', tokens: Object.fromEntries(this.records) };
    let fileDescriptor;
    try {
      fileDescriptor = fs.openSync(tempFile, 'wx', 0o600);
      fs.writeFileSync(fileDescriptor, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
      fs.fsyncSync(fileDescriptor);
      fs.closeSync(fileDescriptor);
      fileDescriptor = undefined;
      fs.renameSync(tempFile, this.storeFile);
      fs.chmodSync(this.storeFile, 0o600);
    } catch (error) {
      if (fileDescriptor !== undefined) {
        fs.closeSync(fileDescriptor);
      }
      fs.rmSync(tempFile, { force: true });
      throw error;
    }
  }

  pruneExpired() {
    const now = Date.now();
    let changed = false;
    for (const [key, record] of this.records) {
      if (record.expires_at <= now) {
        this.records.delete(key);
        changed = true;
      }
    }
    if (changed) {
      this.persist();
    }
  }

  /** Creates a token scoped to one role/region choice. Returns the plaintext token once. */
  create({ role, region, regionCode, datacenter, createdBy, ttlSeconds }) {
    this.pruneExpired();
    const token = crypto.randomBytes(32).toString('base64url');
    const record = {
      role,
      region,
      region_code: regionCode,
      datacenter,
      created_by: createdBy,
      created_at: new Date().toISOString(),
      expires_at: Date.now() + Math.max(1, ttlSeconds) * 1000,
      used: false
    };
    this.records.set(hashToken(token), record);
    this.persist();
    return { token, expiresAt: record.expires_at };
  }

  /** Atomically claims a token for use. Returns the scoped record, or null if invalid/expired/used. */
  claim(token) {
    if (typeof token !== 'string' || !token) {
      return null;
    }
    const key = hashToken(token);
    const record = this.records.get(key);
    if (!record || record.used || record.expires_at <= Date.now()) {
      return null;
    }
    record.used = true;
    this.persist();
    return { key, ...record };
  }

  /** Reverts a claim if the downstream operation (Headscale key creation) failed. */
  release(key) {
    const record = this.records.get(key);
    if (record) {
      record.used = false;
      this.persist();
    }
  }
}

module.exports = { BootstrapTokenStore };
