import { readFileSync } from 'node:fs';
import mysql from 'mysql2/promise';

const STORES = ['BKK-001', 'BKK-002', 'CNX-001', 'HKT-001', 'KKC-001'];

let pool = null;
let schemaReady = false;

// One small, shared pool. A pool that is too large for the DB tier is a classic cause of
// "Too many connections" outages — db.t4g.micro allows only ~60-ish connections.
function getPool(db) {
  if (!pool) {
    pool = mysql.createPool({
      host: db.host,
      port: db.port,
      user: db.user,
      password: db.password,
      database: db.database,
      connectionLimit: 5,
      connectTimeout: 3000,
      waitForConnections: true,
      queueLimit: 20,
      // TLS with certificate verification against the RDS CA bundle (baked into the image).
      // The DB parameter group sets require_secure_transport=1, so plaintext is rejected anyway.
      ssl: db.sslCa ? { ca: readFileSync(db.sslCa, 'utf8'), rejectUnauthorized: true } : undefined,
    });
  }
  return pool;
}

export function isDbConfigured(db) {
  return Boolean(db.host && db.user);
}

async function ensureSchema(p) {
  if (schemaReady) return;
  await p.query(`CREATE TABLE IF NOT EXISTS store_checks (
    id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    store_code VARCHAR(16)  NOT NULL,
    checked_by VARCHAR(64)  NOT NULL,
    checked_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    INDEX idx_checked_at (checked_at)
  )`);
  schemaReady = true;
}

// write=false is a cheap read-only ping (used by /readyz, which may be called very often).
export async function checkDb({ db }, checkedBy = 'unknown', { write = true } = {}) {
  if (!isDbConfigured(db)) {
    return { status: 'not_configured', message: 'DB_HOST / DB_USER not set' };
  }

  const started = performance.now();
  try {
    const p = getPool(db);
    if (!write) {
      await p.query('SELECT 1');
      return { status: 'ok', host: db.host, latencyMs: Math.round(performance.now() - started) };
    }

    await ensureSchema(p);

    // A tiny "real" workload: record a store health check, then read aggregate data back.
    const store = STORES[Math.floor(Math.random() * STORES.length)];
    await p.execute('INSERT INTO store_checks (store_code, checked_by) VALUES (?, ?)', [store, checkedBy]);

    const [[info]] = await p.query(
      'SELECT VERSION() AS version, (SELECT COUNT(*) FROM store_checks) AS totalChecks'
    );
    // SHOW STATUS needs no extra privileges; Ssl_cipher is empty for unencrypted sessions.
    const [[tls]] = await p.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'");

    return {
      status: 'ok',
      host: db.host,
      latencyMs: Math.round(performance.now() - started),
      version: info.version,
      tls: tls?.Value || 'none',
      totalChecks: Number(info.totalChecks),
      lastStore: store,
    };
  } catch (err) {
    return {
      status: 'error',
      host: db.host,
      latencyMs: Math.round(performance.now() - started),
      message: err.code ? `${err.code}: ${err.message}` : err.message,
    };
  }
}

export async function closeDb() {
  if (pool) {
    await pool.end();
    pool = null;
    schemaReady = false;
  }
}
