'use strict';

/**
 * Pluggable authentication boundary.
 *
 * Today this only checks local, admin-issued temporary passwords via UserStore.
 * When VOGON-ID / OAuth login is available, add a new provider module here and
 * dispatch on process.env.AUTH_PROVIDER without changing session or portal code.
 */

const { UserStore } = require('./users');

function createAuthenticator(usersFile) {
  const store = new UserStore(usersFile);

  return {
    /** Returns { username } on success, or null on failure. */
    authenticate(username, password) {
      return store.authenticate(username, password);
    },
    store
  };
}

module.exports = { createAuthenticator };
