// Tiny "single-flight + TTL" cache for expensive, side-effecting reads.
//
// Why (incident 2026-11-10): a vulnerability scanner sent ~480 req/s; ~1,000 of them hit the
// dashboard, and EVERY one did 7 IMDS calls, a DB INSERT + 2 queries and file I/O. The single
// Node process fell behind, its accept queue filled and NGINX returned 504 for ~40 s.
//
//   - TTL: within ttlMs every caller gets the same result (at most one refresh per window).
//   - single-flight: callers arriving while a refresh is running await that same promise instead
//     of starting their own (a burst of 1,000 concurrent requests = 1 refresh, not 1,000).
//   - errors are not cached: the next caller tries again.
export function cached(fn, ttlMs, now = () => Date.now()) {
  let value;
  let expiresAt = 0;
  let inflight = null;

  return function get() {
    if (ttlMs > 0 && now() < expiresAt) return Promise.resolve(value);
    if (inflight) return inflight;

    inflight = (async () => {
      try {
        value = await fn();
        expiresAt = now() + ttlMs;
        return value;
      } finally {
        inflight = null;
      }
    })();
    return inflight;
  };
}
