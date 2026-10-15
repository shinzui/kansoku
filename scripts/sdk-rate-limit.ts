// Consumer proof against mori://shinzui/kansoku-ts/packages/kansoku-js.
// The launcher resolves the canonical package URI; no consumer checkout changes.
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const source = process.env.KANSOKU_TS_SOURCE
assert(source, "resolve the SDK package with Mori before running this proof")
const { createKansoku } = await import(pathToFileURL(source + "/src/index.ts").href)
const attempts: Array<Array<{ eventId: string }>> = []
const scheduled: number[] = []
const originalRandom = Math.random
Math.random = () => 1
const client = createKansoku({
  baseUrl: "http://127.0.0.1:1",
  writeKey: "synthetic-test-only",
  autoStart: false,
  persistQueue: false,
  storage: "memory",
  autocapture: { pageViews: false, sessions: false },
  retryBaseDelayMs: 100,
  maxRetries: 3,
  fetch: async (_input: RequestInfo | URL, init?: RequestInit) => {
    const batch = JSON.parse(String(init?.body))
    attempts.push(batch)
    if (attempts.length <= 2)
      return Response.json({ type: "about:blank", title: "Too Many Requests", status: 429,
        code: "rate_limited", detail: "synthetic rate boundary", retryable: true },
        { status: 429, headers: { "Content-Type": "application/problem+json", "Retry-After": "1" } })
    return Response.json({ accepted: batch.length, rejected: [] }, { status: 202 })
  },
  timers: {
    setTimeout: ((handler: TimerHandler, milliseconds: number, ...args: unknown[]) => {
      if (milliseconds < 10000) scheduled.push(milliseconds)
      return globalThis.setTimeout(handler, milliseconds < 10000 ? 2 : milliseconds, ...args)
    }) as typeof setTimeout,
    clearTimeout: globalThis.clearTimeout,
  },
})
try {
  client.track("native_rate_limit_probe", { count: 1 })
  await client.flush()
  assert.equal(attempts.length, 3)
  assert.deepEqual(attempts.map((batch) => batch.length), [1, 1, 1])
  assert.equal(new Set(attempts.flat().map((event) => event.eventId)).size, 1)
  // This SDK uses its existing exponential jitter policy for 429; unlike the
  // Haskell client it does not currently consume Retry-After as a minimum.
  assert.deepEqual(scheduled, [100, 200])
  assert.equal(client.stats.accepted, 1)
  assert.equal(client.stats.dropped, 0)
  assert.equal(client.stats.queued, 0)
  console.log("Browser SDK: two 429 retries, stable event ID, exponential scheduling and eventual acceptance passed.")
} finally {
  Math.random = originalRandom
  await client.shutdown()
}
