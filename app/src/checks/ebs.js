import { appendFile, mkdir, readFile, statfs } from 'node:fs/promises';
import path from 'node:path';

const LOG_FILE = 'health.log';
const KEEP_LINES = 5;

// Proves the persistent volume works: write a line, read back the tail, report free space.
// On EC2 the host mounts the EBS volume at /mnt/app-data and Docker bind-mounts it to DATA_DIR.
export async function checkEbs({ dataDir }, now = new Date()) {
  const file = path.join(dataDir, LOG_FILE);
  try {
    await mkdir(dataDir, { recursive: true });
    await appendFile(file, `${now.toISOString()} health-check ok\n`);

    const lines = (await readFile(file, 'utf8')).trim().split('\n');
    const fs = await statfs(dataDir);
    const totalBytes = fs.blocks * fs.bsize;
    const freeBytes = fs.bavail * fs.bsize;

    return {
      status: 'ok',
      path: dataDir,
      totalWrites: lines.length,
      recent: lines.slice(-KEEP_LINES),
      totalGiB: +(totalBytes / 1024 ** 3).toFixed(2),
      freeGiB: +(freeBytes / 1024 ** 3).toFixed(2),
      usedPercent: totalBytes ? Math.round(((totalBytes - freeBytes) / totalBytes) * 100) : 0,
    };
  } catch (err) {
    return { status: 'error', path: dataDir, message: err.message };
  }
}
