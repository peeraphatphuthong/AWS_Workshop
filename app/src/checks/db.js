import mysql from 'mysql2/promise';

let pool = null;

// One small, shared pool. A pool that is too large for the DB tier is a classic cause of
// "Too many connections" outages — db.t3.micro allows only ~60-ish connections.
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
    });
  }
  return pool;
}

export function isDbConfigured(db) {
  return Boolean(db.host && db.user);
}

export async function checkDb({ db }) {
  if (!isDbConfigured(db)) {
    return { status: 'not_configured', message: 'DB_HOST / DB_USER not set (RDS arrives in Phase 5)' };
  }

  const started = performance.now();
  try {
    const [rows] = await getPool(db).query(
      'SELECT VERSION() AS version, @@hostname AS hostname, NOW() AS now'
    );
    return {
      status: 'ok',
      host: db.host,
      latencyMs: Math.round(performance.now() - started),
      version: rows[0].version,
      serverTime: rows[0].now,
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
  }
}
