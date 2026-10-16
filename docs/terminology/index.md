---
okf_version: "0.2"
---

# Kansoku terminology

Controlled vocabulary for developers familiar with analytics who are new to Kansoku. Definitions describe the current checkout and link to contracts, guides and executable evidence; they do not promise a released stable interface. Topic groups reflect reader journeys, while stable TERM handles preserve concept identity across renames.

The frozen [profile](profile.dhall) selects [documentation.terminology](mori://shinzui/okf-profiles/profiles/terminology) v0.20.0. Canonical example: `mori://shinzui/kansoku/okf/terminology/concepts/TERM-1`. Related links are associations; broader links identify a more general concept. No independent verification is claimed.

See [capabilities](../capabilities/index.md) for what can be adopted, [guides](../README.md) for instructions and the [adoption log](log.md) for changes. Validate with `just terminology-check`. Preserve these topic groups when reconciling the index.

## Events and contracts

| ID | Term | Definition |
| --- | --- | --- |
| TERM-1 | [analytics event](analytics-event.md) | A producer observation of behaviour carried in Kansoku’s canonical event envelope. |
| TERM-2 | [event ID](event-id.md) | The producer-generated key that permanently identifies one logical event within an account. |
| TERM-3 | [event name](event-name.md) | The behaviour label used to select an event’s schema and analytical meaning. |
| TERM-4 | [event source](event-source.md) | The origin category of an observation, chosen from web, app, service, worker, email or agent. |
| TERM-5 | [source service](source-service.md) | The optional producer name that distinguishes applications or properties inside an account. |
| TERM-9 | [schema version](schema-version.md) | The producer-selected version of a declared event’s property contract. |
| TERM-10 | [schema catalog](schema-catalog.md) | The published machine-readable registry of governed event versions, property constraints and identifier kinds. |
| TERM-11 | [occurrence time](occurrence-time.md) | The accepted time at which an observation happened, used for analytical ordering and buckets. |
| TERM-12 | [receipt time](receipt-time.md) | The server-assigned time of first event acceptance. |
| TERM-13 | [send time](send-time.md) | The optional producer delivery timestamp used to correct future occurrence-time skew at acceptance. |
| TERM-14 | [event property](event-property.md) | A value in an event’s properties object describing that particular observation. |
| TERM-15 | [event context](event-context.md) | The event’s JSON context object carrying supplementary producer metadata. |

## Accounts and credentials

| ID | Term | Definition |
| --- | --- | --- |
| TERM-6 | [account](account.md) | The credential-derived boundary within which Kansoku accepts events and authorizes analytical reads. |
| TERM-7 | [write key](write-key.md) | An account-scoped producer credential that admits events but cannot query metrics or manage analytical resources. |
| TERM-8 | [service token](service-token.md) | An account-scoped credential that permits event ingestion and protected analytics or resource operations. |

## Acceptance, delivery and recovery

| ID | Term | Definition |
| --- | --- | --- |
| TERM-16 | [partial batch acknowledgement](partial-batch-acknowledgement.md) | An HTTP 202 response that reports acceptance and indexed rejection outcomes for individual submitted events. |
| TERM-17 | [immutable acceptance](immutable-acceptance.md) | The rule that an account/event ID retains its first accepted producer payload and normalization across retries. |
| TERM-18 | [acceptance ledger](acceptance-ledger.md) | The durable PostgreSQL record of logical event identities, producer hashes, first acceptance times and erasure dispositions. |
| TERM-19 | [rejection quarantine](rejection-quarantine.md) | The optional bounded diagnostic store for individual events rejected during ingest validation. |
| TERM-20 | [private queue envelope](private-queue-envelope.md) | The versioned internal delivery record that preserves an accepted event and its ingestion-derived decisions for the writer. |
| TERM-21 | [at-least-once delivery](at-least-once-delivery.md) | The queue-to-writer policy under which an accepted event can be delivered physically more than once. |
| TERM-22 | [canonical fact](canonical-fact.md) | The single logical retained event used by analytics after physical duplicate deliveries are removed. |
| TERM-23 | [archive](archive.md) | The queue’s retained message store for dead-lettered or otherwise archived delivery envelopes. |
| TERM-24 | [replay](replay.md) | A repeated delivery of existing accepted facts that preserves their logical event identity. |
| TERM-25 | [writer breaker](writer-breaker.md) | The writer recovery state that parks an unchanged batch and pauses source consumption when insertion cannot proceed. |

## Identity, traits and organisations

| ID | Term | Definition |
| --- | --- | --- |
| TERM-26 | [anonymous ID](anonymous-id.md) | The producer identifier for activity without a directly asserted user identity. |
| TERM-27 | [explicit user ID](explicit-user-id.md) | The producer’s direct assertion of which user performed an event. |
| TERM-28 | [identifier signal](identifier-signal.md) | A typed opaque identifier supplied as evidence for resolving an event’s user. |
| TERM-29 | [identity evidence](identity-evidence.md) | Retained account-scoped observations linking identifier signals or session contexts to explicit users. |
| TERM-30 | [canonical subject](canonical-subject.md) | The resolved identity used to count and join an analytical event. |
| TERM-31 | [identity conflict](identity-conflict.md) | Evidence that one signal or session context refers to multiple users and cannot choose a unique binding by itself. |
| TERM-32 | [current person trait](current-person-trait.md) | A governed per-user value joined to analytics according to its current winning observation. |
| TERM-33 | [set-once trait](set-once-trait.md) | A governed user-trait initialization used only when no set observation exists for that key. |
| TERM-34 | [organisation](organisation.md) | A business grouping of analytics activity and users within a Kansoku account. |
| TERM-35 | [current organisation trait](current-organisation-trait.md) | A governed value from group v2 observations used to classify an organisation’s historical activity. |
| TERM-36 | [current organisation membership](current-organisation-membership.md) | The latest explicit-user group observation used as optional fallback for an event missing an organisation ID. |
| TERM-75 | [fingerprint expiry](fingerprint-expiry.md) | The separate 180-day policy limiting eligible fingerprint evidence and cleaning expired fingerprint material. |

## Query contracts

| ID | Term | Definition |
| --- | --- | --- |
| TERM-37 | [metric point](metric-point.md) | One numeric analytical result with a nullable bucket and a dimension-value group object. |
| TERM-38 | [dimension](dimension.md) | A validated attribute by which a metric selects or groups its population. |
| TERM-39 | [metric filter](metric-filter.md) | A typed population predicate applied through bounded conjoined groups of optional alternatives. |
| TERM-40 | [time grain](time-grain.md) | The calendar unit used to bucket supported metric results in UTC. |
| TERM-41 | [half-open range](half-open-range.md) | An analytical time interval that includes its from boundary and excludes its to boundary. |
| TERM-42 | [complete-or-error answer](complete-or-error.md) | A metric response policy that returns the whole aggregate within public limits or fails without a partial metric payload. |
| TERM-79 | [problem details](problem-details.md) | The structured application/problem+json error contract carrying HTTP status, stable code and retryability. |

## Activity and retention

| ID | Term | Definition |
| --- | --- | --- |
| TERM-43 | [active user](active-user.md) | A nonempty canonical subject with matching non-profile activity in the requested activity population. |
| TERM-44 | [rolling window](rolling-window.md) | A trailing activity interval evaluated for each closed daily observation point. |
| TERM-45 | [stickiness](stickiness.md) | The ratio of daily active subjects to rolling-thirty-day active subjects in the same selected population. |
| TERM-46 | [lifecycle](lifecycle.md) | The classification of daily activity into new, returning, resurrecting and dormant populations using retained matching history. |
| TERM-47 | [retention cohort](retention-cohort.md) | The starting population whose later matching activity is measured at requested return offsets. |
| TERM-48 | [retained-history lifetime](retained-history-lifetime.md) | The available retained matching history used for first-activity analytics. |
| TERM-49 | [retention offset](retention-offset.md) | A number of days after a retention cohort’s start at which return activity is evaluated. |

## Reusable segments and metrics

| ID | Term | Definition |
| --- | --- | --- |
| TERM-50 | [saved cohort](saved-cohort.md) | An account-scoped named definition of an identified-user segment reusable in metric selection and grouping. |
| TERM-51 | [behavioural cohort](behavioural-cohort.md) | A saved cohort whose membership is evaluated from event conditions and current person traits at query time. |
| TERM-52 | [static cohort](static-cohort.md) | A saved cohort whose membership is an explicitly uploaded set of user IDs. |
| TERM-68 | [custom metric](custom-metric.md) | A typed ad-hoc or saved analytical calculation over explicitly selected event names. |
| TERM-69 | [saved metric definition](saved-metric-definition.md) | An account-scoped named custom metric specification stored for repeated execution. |

## Sessions and acquisition

| ID | Term | Definition |
| --- | --- | --- |
| TERM-53 | [web session](web-session.md) | The whole retained set of web events sharing an account, source service and nonempty producer session ID. |
| TERM-54 | [first-touch attribution](first-touch-attribution.md) | The selection of an initial eligible observation as the owner of analytical attributes. |
| TERM-55 | [bounce rate](bounce-rate.md) | The fraction of selected sessions with exactly one distinct page view and no engagement event. |
| TERM-56 | [observed session duration](observed-session-duration.md) | The elapsed time from the first to the last retained observed event in a web session. |
| TERM-57 | [acquisition channel](acquisition-channel.md) | The server-derived category of a session’s attributed campaign or external referrer. |
| TERM-58 | [bot flag](bot-flag.md) | The accepted classification marking an event as automated traffic under server or producer rules. |

## Funnels and paths

| ID | Term | Definition |
| --- | --- | --- |
| TERM-59 | [funnel](funnel.md) | A bounded progression through requested event steps for a canonical user or supported organisation timeline. |
| TERM-60 | [selected chain](selected-chain.md) | The deterministic matched event sequence used to report a unique participant’s funnel reach and timing. |
| TERM-61 | [funnel attempt](funnel-attempt.md) | A nonoverlapping entry tracked when funnel counting is set to totals. |
| TERM-62 | [time to convert](time-to-convert.md) | The elapsed selected-chain time from funnel start to a reached step, reported as exact percentile measures. |
| TERM-63 | [path](path.md) | An observed sequence of canonical-user transitions explored forward or backward within a bounded interval. |

## Experiments

| ID | Term | Definition |
| --- | --- | --- |
| TERM-64 | [experiment exposure](experiment-exposure.md) | An experiment_viewed observation that records a user seeing a named experiment variant. |
| TERM-65 | [exposure contamination](exposure-contamination.md) | The condition in which a resolved user has observed more than one variant of an experiment within the diagnostic scope. |
| TERM-66 | [first-observed assignment](first-observed-assignment.md) | The exclusive diagnostic allocation of a resolved user to their earliest valid observed experiment variant in a scope. |
| TERM-67 | [exposure sketch](exposure-sketch.md) | The approximate raw-identity aggregate used for default unsegmented experiment exposure counts. |

## Operations and data lifecycle

| ID | Term | Definition |
| --- | --- | --- |
| TERM-70 | [maintenance fence](maintenance-fence.md) | The persisted global admission boundary held while a cross-store maintenance job drains and mutates analytical state. |
| TERM-71 | [maintenance job](maintenance-job.md) | The durable administrative workflow record used to checkpoint, inspect and resume cross-store data maintenance. |
| TERM-72 | [identity unlinking](identity-unlinking.md) | The default erasure operation that removes matching identity links and current traits while preserving explicit historical event facts. |
| TERM-73 | [explicit-fact deletion](explicit-fact-deletion.md) | The confirmed erasure mode that additionally removes the target account/user’s explicitly attributed event facts. |
| TERM-74 | [applied retention cutoff](applied-retention-cutoff.md) | The persisted UTC event boundary advanced by a confirmed retention job and enforced by analytical reads and later writes. |
| TERM-76 | [reader projection](reader-projection.md) | A documented ClickHouse view exposed to trusted SQL consumers with an explicit analytical column contract. |
| TERM-77 | [readiness](readiness.md) | The operational determination that the process and required pipeline dependencies can currently serve traffic within configured thresholds. |
| TERM-78 | [liveness](liveness.md) | The operational check that the HTTP process responds independently of dependency health. |
