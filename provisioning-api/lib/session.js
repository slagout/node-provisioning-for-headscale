'use strict';

const crypto = require('node:crypto');

const SESSION_COOKIE_NAME = 'ecosynq_session';

function base64url(buffer) {
  return buffer.toString('base64url');
}

class SessionManager {
  constructor(secret, { ttlSeconds = 1800 } = {}) {
    if (Buffer.byteLength(secret) < 32) {
      throw new Error('Session secret must contain at least 32 bytes');
    }
    this.secret = secret;
    this.ttlSeconds = ttlSeconds;
  }

  sign(payload) {
    const body = base64url(Buffer.from(JSON.stringify(payload), 'utf8'));
    const mac = base64url(crypto.createHmac('sha256', this.secret).update(body).digest());
    return `${body}.${mac}`;
  }

  verify(token) {
    if (typeof token !== 'string') {
      return null;
    }
    const parts = token.split('.');
    if (parts.length !== 2) {
      return null;
    }
    const [body, mac] = parts;
    const expectedMac = base64url(crypto.createHmac('sha256', this.secret).update(body).digest());
    const macBuffer = Buffer.from(mac);
    const expectedBuffer = Buffer.from(expectedMac);
    if (macBuffer.length !== expectedBuffer.length || !crypto.timingSafeEqual(macBuffer, expectedBuffer)) {
      return null;
    }
    let payload;
    try {
      payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    } catch {
      return null;
    }
    if (!payload || typeof payload.exp !== 'number' || payload.exp <= Date.now()) {
      return null;
    }
    return payload;
  }

  createCookie(username) {
    const expiresAt = Date.now() + this.ttlSeconds * 1000;
    const token = this.sign({ username, exp: expiresAt });
    return {
      name: SESSION_COOKIE_NAME,
      value: token,
      options: {
        httpOnly: true,
        secure: true,
        sameSite: 'strict',
        path: '/',
        maxAge: this.ttlSeconds * 1000
      }
    };
  }

  readUser(req) {
    const token = parseCookie(req.headers.cookie, SESSION_COOKIE_NAME);
    const payload = this.verify(token);
    return payload ? { username: payload.username } : null;
  }
}

function parseCookie(cookieHeader, name) {
  if (typeof cookieHeader !== 'string') {
    return undefined;
  }
  for (const part of cookieHeader.split(';')) {
    const separatorIndex = part.indexOf('=');
    if (separatorIndex === -1) {
      continue;
    }
    const key = part.slice(0, separatorIndex).trim();
    if (key === name) {
      return decodeURIComponent(part.slice(separatorIndex + 1).trim());
    }
  }
  return undefined;
}

function serializeCookie(cookie) {
  const { name, value, options } = cookie;
  const segments = [`${name}=${encodeURIComponent(value)}`];
  if (options.maxAge !== undefined) {
    segments.push(`Max-Age=${Math.floor(options.maxAge / 1000)}`);
  }
  if (options.path) {
    segments.push(`Path=${options.path}`);
  }
  if (options.sameSite) {
    segments.push(`SameSite=${options.sameSite === 'strict' ? 'Strict' : options.sameSite}`);
  }
  if (options.httpOnly) {
    segments.push('HttpOnly');
  }
  if (options.secure) {
    segments.push('Secure');
  }
  return segments.join('; ');
}

function clearedCookie() {
  return `${SESSION_COOKIE_NAME}=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Strict`;
}

module.exports = { SessionManager, SESSION_COOKIE_NAME, serializeCookie, clearedCookie };
