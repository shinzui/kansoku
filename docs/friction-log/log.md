# Bundle Update Log

## 2026-11-06
* **Update**: FRIC-5 resolved: Registered the omitted custom metric test group and verified it in the passing deterministic transcript.
* **Addition**: FRIC-5 records detour tooling friction with mori://shinzui/kansoku: Custom metric validation specs were compiled but never executed
* **Update**: FRIC-4 resolved: Fixed focused acceptance command output handling
* **Update**: FRIC-3 accepted: Accepted log writer limitation with preservation workaround
* **Addition**: FRIC-4 records detour tooling friction with mori://shinzui/kansoku: Focused acceptance helper discards ownership query output
* **Addition**: FRIC-3 records detour tooling friction with mori://shinzui/okf: OKF log add rewrites existing log prose
* **Update**: FRIC-2 resolved: Make the owned test server timezone explicit to match UTC schema timestamps and expiry fixtures.
* **Addition**: FRIC-2 records detour tooling friction with mori://shinzui/kansoku: Owned acceptance repeatedly fails fingerprint expiry fixture
* **Update**: FRIC-1 accepted: Accepted the local restoration workaround; the tool limitation remains upstream.
* **Addition**: FRIC-1 records detour tooling friction with mori://shinzui/okf: OKF log append removes existing guide provenance prose
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
