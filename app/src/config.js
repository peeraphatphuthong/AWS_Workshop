// All configuration comes from environment variables (12-factor app).
// The same image runs locally, in CI and on EC2 — only the env differs.
export function loadConfig(env = process.env) {
  return {
    port: Number(env.PORT ?? 3000),
    appVersion: env.APP_VERSION ?? 'dev',
    gitSha: env.GIT_SHA ?? 'local',
    dataDir: env.DATA_DIR ?? '/data',
    // Set IMDS_DISABLED=true off EC2 (local dev / CI) to skip the metadata calls entirely.
    imdsDisabled: env.IMDS_DISABLED === 'true',
    imdsEndpoint: env.IMDS_ENDPOINT ?? 'http://169.254.169.254',
    db: {
      host: env.DB_HOST ?? '',
      port: Number(env.DB_PORT ?? 3306),
      user: env.DB_USER ?? '',
      password: env.DB_PASSWORD ?? '',
      database: env.DB_NAME ?? '',
    },
  };
}
