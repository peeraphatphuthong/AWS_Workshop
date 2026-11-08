const escapeHtml = (value) =>
  String(value ?? '—').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

const BADGE = {
  ok: ['Healthy', 'ok'],
  skipped: ['Skipped', 'muted'],
  not_configured: ['Not configured', 'muted'],
  unavailable: ['Unavailable', 'warn'],
  error: ['Error', 'bad'],
};

function badge(status) {
  const [label, cls] = BADGE[status] ?? [status, 'muted'];
  return `<span class="badge ${cls}">${escapeHtml(label)}</span>`;
}

function rows(pairs) {
  return pairs
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `<tr><th>${escapeHtml(k)}</th><td><code>${escapeHtml(v)}</code></td></tr>`)
    .join('');
}

function card(title, check, pairs) {
  const body = check.status === 'ok' ? rows(pairs) : rows([['Message', check.message]]);
  return `<section class="card">
    <header><h2>${escapeHtml(title)}</h2>${badge(check.status)}</header>
    <table>${body}</table>
  </section>`;
}

export function renderDashboard(s) {
  const { ec2, ebs, db, app } = s;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Retail Store Health</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --text:#1d2330; --muted:#6b7280; --line:#e5e7eb;
          --ok:#15803d; --okbg:#dcfce7; --warn:#a16207; --warnbg:#fef9c3; --bad:#b91c1c; --badbg:#fee2e2; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0f141c; --card:#171e29; --text:#e6e9ef; --muted:#9aa4b2; --line:#263042;
            --okbg:#123321; --ok:#4ade80; --warnbg:#3a2f0b; --warn:#facc15; --badbg:#3b1414; --bad:#f87171; }
  }
  * { box-sizing:border-box }
  body { margin:0; font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif; background:var(--bg); color:var(--text) }
  main { max-width:960px; margin:0 auto; padding:32px 16px }
  h1 { margin:0 0 4px; font-size:24px }
  .sub { color:var(--muted); margin:0 0 24px }
  .grid { display:grid; gap:16px; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)) }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:16px }
  .card header { display:flex; justify-content:space-between; align-items:center; margin-bottom:8px }
  h2 { font-size:16px; margin:0 }
  table { width:100%; border-collapse:collapse }
  th { text-align:left; font-weight:500; color:var(--muted); padding:4px 8px 4px 0; width:40%; vertical-align:top }
  td { padding:4px 0; word-break:break-all }
  code { font:13px ui-monospace,SFMono-Regular,Consolas,monospace }
  .badge { font-size:12px; font-weight:600; padding:2px 10px; border-radius:999px }
  .ok { background:var(--okbg); color:var(--ok) } .warn { background:var(--warnbg); color:var(--warn) }
  .bad { background:var(--badbg); color:var(--bad) } .muted { background:var(--line); color:var(--muted) }
  footer { margin-top:24px; color:var(--muted); font-size:13px }
  a { color:inherit }
</style>
</head>
<body>
<main>
  <h1>Retail Store Health</h1>
  <p class="sub">Infrastructure status of the store backend — provisioned with Terraform on AWS.</p>
  <div class="grid">
    ${card('Compute — EC2', ec2, [
      ['Instance ID', ec2.instanceId],
      ['Type', ec2.instanceType],
      ['Availability Zone', ec2.availabilityZone],
      ['Private IP', ec2.privateIp],
      ['Public IP (EIP)', ec2.publicIp],
      ['AMI', ec2.amiId],
    ])}
    ${card('Storage — EBS', ebs, [
      ['Mount path', ebs.path],
      ['Size / free', ebs.totalGiB !== undefined ? `${ebs.totalGiB} GiB / ${ebs.freeGiB} GiB` : undefined],
      ['Used', ebs.usedPercent !== undefined ? `${ebs.usedPercent}%` : undefined],
      ['Writes so far', ebs.totalWrites],
      ['Last write', ebs.recent?.at(-1)],
    ])}
    ${card('Database — RDS MySQL', db, [
      ['Endpoint', db.host],
      ['Engine version', db.version],
      ['Query latency', db.latencyMs !== undefined ? `${db.latencyMs} ms` : undefined],
      ['Server time', db.serverTime],
    ])}
  </div>
  <footer>
    Version <code>${escapeHtml(app.version)}</code> · commit <code>${escapeHtml(app.gitSha)}</code> ·
    uptime ${escapeHtml(app.uptimeSeconds)}s · checked ${escapeHtml(app.checkedAt)} ·
    <a href="/api/status">JSON</a>
  </footer>
</main>
</body>
</html>`;
}
