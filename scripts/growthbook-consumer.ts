// Executes the pinned, unmodified upstream ClickHouse adapter and query-editor
// validation against the actual constrained reader; it starts no app database.
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"

async function main() {
  const source = process.env.KANSOKU_GROWTHBOOK_SOURCE
  const inputPath = process.env.KANSOKU_CONSUMER_INPUT
  assert(source && inputPath, "owned GrowthBook source/input are required")
  const input = JSON.parse(await readFile(inputPath, "utf8"))
  const { default: ClickHouse } = require(
    source + "/packages/back-end/src/integrations/ClickHouse.ts",
  )
  const { encryptParams } = require(source + "/packages/back-end/src/services/datasource.ts")
  const datasource = {
    id: "kansoku-read-contract",
    organization: "owned-fixture",
    type: "clickhouse",
    settings: {},
    params: encryptParams(input.connection),
  }
  const integration = new ClickHouse(
    { userId: "owned-fixture", userName: "owned fixture" },
    datasource,
  )
  assert.equal(await integration.testConnection(), true)
  let cases = 1
  for (const [name, query, columns] of [
    ["assignments", input.assignments, ["user_id", "timestamp", "experiment_id", "variation_id"]],
    ["facts", input.facts, ["user_id", "timestamp", "amount"]],
  ] as const) {
    const validation = integration.getTestValidityQuery(query, 365, undefined, "timestamp")
    const schema = await integration.runTestQuery(validation, ["timestamp"], "freeFormQuery")
    assert.deepEqual(
      schema.columns.map((column: { name: string }) => column.name),
      columns,
    )
    const sample = integration.getTestQuery({
      query,
      limit: 100,
      testDays: 365,
      timestampColumn: "timestamp",
    })
    const result = await integration.runTestQuery(sample, ["timestamp"], "freeFormQuery")
    assert.equal(result.results.length, input.expected[name].length)
    const normalized = result.results.map((row: Record<string, unknown>) => ({
      ...row,
      timestamp: (row.timestamp as Date).toISOString(),
    }))
    const sort = (rows: unknown[]) => rows.map((row) => JSON.stringify(row)).sort()
    assert.deepEqual(sort(normalized), sort(input.expected[name]))
    cases++
  }
  try {
    await integration.runQuery("SELECT count() FROM analytics.events_raw", undefined, {
      queryType: "freeFormQuery",
    })
    assert.fail("reader selected excluded storage")
  } catch (error) {
    assert.match(String(error), /ACCESS_DENIED|Not enough privileges/)
  }
  cases++
  assert.equal(cases, 4)
  console.log(
    JSON.stringify({
      consumer: "GrowthBook",
      version: "5.1.0",
      cases,
      skipped: 0,
      result: "passed",
    }),
  )
}
main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
