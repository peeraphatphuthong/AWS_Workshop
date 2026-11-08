// Reads instance metadata with IMDSv2 (session token), the secure version of the metadata service.
// IMDSv1 (plain GET) is what SSRF attacks abuse to steal instance-role credentials, so in Phase 4
// we will force `http_tokens = "required"` on the instance.

const TIMEOUT_MS = 800;

async function imdsFetch(url, options = {}) {
  const res = await fetch(url, { ...options, signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!res.ok) throw new Error(`IMDS ${url} -> HTTP ${res.status}`);
  return res.text();
}

export async function checkEc2({ imdsDisabled, imdsEndpoint }) {
  if (imdsDisabled) {
    return { status: 'skipped', message: 'IMDS disabled (not running on EC2)' };
  }

  try {
    // 1) Get a short-lived session token (PUT). Containers need hop limit >= 2 to reach this.
    const token = await imdsFetch(`${imdsEndpoint}/latest/api/token`, {
      method: 'PUT',
      headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '60' },
    });
    const headers = { 'X-aws-ec2-metadata-token': token };
    const get = (path) => imdsFetch(`${imdsEndpoint}/latest/meta-data/${path}`, { headers });
    const optional = (path) => get(path).catch(() => null);

    const [instanceId, instanceType, az, privateIp, publicIp, amiId] = await Promise.all([
      get('instance-id'),
      get('instance-type'),
      get('placement/availability-zone'),
      get('local-ipv4'),
      optional('public-ipv4'), // absent when no public IP / EIP is attached
      get('ami-id'),
    ]);

    return {
      status: 'ok',
      instanceId,
      instanceType,
      availabilityZone: az,
      privateIp,
      publicIp,
      amiId,
    };
  } catch (err) {
    return { status: 'unavailable', message: `Cannot reach instance metadata: ${err.message}` };
  }
}
