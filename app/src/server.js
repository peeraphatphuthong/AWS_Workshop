import { createApp } from './app.js';
import { loadConfig } from './config.js';
import { closeDb } from './checks/db.js';

const config = loadConfig();
const app = createApp(config);

const server = app.listen(config.port, () => {
  // Structured (JSON) logs are easy to query later in CloudWatch Logs Insights.
  console.log(JSON.stringify({ level: 'info', msg: 'server started', port: config.port, version: config.appVersion, gitSha: config.gitSha }));
});

// Graceful shutdown: `docker stop` sends SIGTERM, then SIGKILL after 10s.
// Finish in-flight requests and close DB connections instead of dropping them.
function shutdown(signal) {
  console.log(JSON.stringify({ level: 'info', msg: 'shutting down', signal }));
  server.close(async () => {
    await closeDb();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 8000).unref();
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
