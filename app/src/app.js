import express from 'express';
import { checkEc2 } from './checks/ec2.js';
import { checkEbs } from './checks/ebs.js';
import { checkDb, isDbConfigured } from './checks/db.js';
import { renderDashboard } from './view.js';

export function createApp(config) {
  const app = express();
  app.disable('x-powered-by');
  // Behind NGINX: trust the X-Forwarded-* headers it sets.
  app.set('trust proxy', 'loopback, uniquelocal');

  async function collectStatus() {
    const [ec2, ebs, db] = await Promise.all([checkEc2(config), checkEbs(config), checkDb(config)]);
    return {
      app: {
        version: config.appVersion,
        gitSha: config.gitSha,
        uptimeSeconds: Math.round(process.uptime()),
        checkedAt: new Date().toISOString(),
      },
      ec2,
      ebs,
      db,
    };
  }

  // Liveness: is the process alive? Never depends on downstream systems,
  // otherwise a DB blip would make the orchestrator restart healthy containers.
  app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

  // Readiness: can this instance serve real traffic right now?
  app.get('/readyz', async (_req, res) => {
    const [ebs, db] = await Promise.all([checkEbs(config), checkDb(config)]);
    const dbOk = !isDbConfigured(config.db) || db.status === 'ok';
    const ready = ebs.status === 'ok' && dbOk;
    res.status(ready ? 200 : 503).json({ ready, ebs: ebs.status, db: db.status });
  });

  app.get('/api/status', async (_req, res, next) => {
    try {
      res.json(await collectStatus());
    } catch (err) {
      next(err);
    }
  });

  app.get('/', async (_req, res, next) => {
    try {
      res.type('html').send(renderDashboard(await collectStatus()));
    } catch (err) {
      next(err);
    }
  });

  app.use((_req, res) => res.status(404).json({ error: 'not found' }));

  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    console.error(JSON.stringify({ level: 'error', msg: err.message, stack: err.stack }));
    res.status(500).json({ error: 'internal error' });
  });

  return app;
}
