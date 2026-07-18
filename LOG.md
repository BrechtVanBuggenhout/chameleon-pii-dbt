# chameleon_pii — project log

What has shipped, what state the package is in, and what comes next.
(Newest release last; see git tags for exact code.)

## Status — 2026-07-18

**Feature-complete, PUBLIC, and cross-warehouse** (repo public 2026-07-09, CI green,
launch post live at chameleon-data.com/learn/dbt-pii-package). Five models, tests
riding on `dbt build`, CI with keyless (WIF) auth against a dedicated
`chameleon_pii_ci` BigQuery dataset. Snowflake support verified end-to-end
2026-07-18 against a real trial account. Pinned at `v0.9.0` by the consuming
project (`chameleon-dataplatform-dbt`). Also feeds Chameleon's Key Vault registry
(federated: connector + dbt + manual slices; dbt slice activates when
`PII_REGISTRY_DATASET_ID` is set).

## Release history

| Tag | What shipped |
|---|---|
| v0.1.0 | Core: `pii_registry` + `pii_field_lineage`. Graph-only (zero warehouse queries): `meta.pii` declarations + name inference, DAG BFS for "used where" lineage. |
| v0.2.0 | `pii_discovery`: reads column names from `INFORMATION_SCHEMA.COLUMNS` across configurable datasets, flags PII-looking columns never declared. Caught the real `dim_users.email_token` mart-layer leak. |
| v0.3.0 | `pii_shred_readiness`: per-field verdict READY / AT_RISK / NOT_SHREDDABLE / UNREGISTERED, composing registry + discovery + lineage. |
| v0.4.0 | `no_undeclared_pii` generic test — shift-left CI enforcement (`pii_undeclared_severity: error` in CI, allowlist supported). |
| v0.5.0 | `pii_content_findings`: opt-in **value** scanning (email/phone/ssn/cc/ip regexes) on name-innocent STRING columns. Guardrails: off by default, TABLESAMPLE, `maximum_bytes_billed` cap. |
| v0.6.0 | 22 lightweight dbt tests riding on `dbt build` (accepted_values on enums, not_null on keys, 3 singular invariants). |
| v0.7.0 | GitHub Actions CI with keyless WIF auth + nested `integration_tests/` project with planted-PII fixtures proving detection end-to-end. Documented the **two-phase build order** requirement (discovery/content models must run after the models they scan exist). |
| v0.8.0 | First-run UX: `pii_auto_register_discovered` (default on) flows discovery findings into `pii_registry` as visibility entries (`detection_method = INFORMATION_SCHEMA`; still count as undeclared for the test + UNREGISTERED verdict — readiness filters them from its declared branch). `dbt run-operation pii_report` prints a terminal summary (registry/lineage/readiness counts, undeclared findings with allowlist status, next steps). README restructured to lead with the zero-config quick start. |
| v0.9.0 | **Snowflake support, verified against a real account.** Ran the full 3-phase integration build (fixtures → package models → tests) on Snowflake: identical results to BigQuery on the same fixture (registry 7 fields/3 tables, lineage 1 flow, readiness 1 READY/2 AT_RISK/4 UNREGISTERED, discovery WARN=4 by design). Two real bugs found and fixed: (1) the two content-scan detection tests were BigQuery-only by design but ran unconditionally — gated with `{{ config(enabled = target.type == 'bigquery') }}`; (2) `pii_report`'s `run_query()` calls used unquoted SQL aliases, which Snowflake uppercases — every `row['field']` lookup silently returned nothing (registry/lineage/readiness counts and the undeclared-findings list all printed blank). Fixed by routing every alias through `adapter.quote()` (backticks on BigQuery, double quotes on Snowflake) instead of hardcoding one quoting style. Verified the fix on both adapters before and after. |

## Known limitations

- Value-level content scanning (`pii_content_findings`) is **BigQuery only**;
  builds an empty portable-typed table on Snowflake and other adapters.
- Graph-based models only see columns documented in `schema.yml`; discovery
  fills the gap via INFORMATION_SCHEMA but fuller lineage needs catalog.json.
- Fresh `dbt build` runs discovery/content scans before target models exist →
  two-phase build documented in README; no dependency edge can express it.
- Name patterns are deliberately high-recall (e.g. bare `name$` false-positives
  on `subscription_name`); tune via vars, review findings.

## Next steps

### Distribution (highest leverage — the package is the adoption wedge)
1. ~~Finish CI activation~~ DONE 2026-07-09 (variables set, workflow green on push).
2. ~~Make the repo public~~ DONE 2026-07-09. **Submit to dbt Hub** — still open.
3. ~~Launch write-up~~ DONE 2026-07-09 — live at
   chameleon-data.com/learn/dbt-pii-package. **Distribution posts still open**:
   dbt Slack #i-made-this, r/dataengineering, LinkedIn, all pointing at the article.
4. Add a README badge for CI + a screenshot/GIF of `dbt run-operation pii_report`
   output (the report is now the natural screenshot).
5. Update distribution posts to mention Snowflake support now that it's real
   (widens the "which warehouse do you use" objection away).

### Product (build only when pulled by real users)
6. ~~Cross-warehouse via `adapter.dispatch` — Snowflake~~ DONE 2026-07-18,
   verified against a real trial account (see v0.9.0 above). Not yet in CI
   (would need Snowflake secrets in GitHub Actions — skipped for now since the
   trial account is personal; revisit if a Snowflake-using design partner
   shows up).
7. Resource-level policy knobs declared in dbt (`meta.chameleon`:
   deletionStrategy, user/tenant columns) instead of derived defaults in
   Key Vault's `BigQueryPiiRegistryRepository`.
8. `pii_scan_events` append-only diff log (cheap forever-history of findings).
9. Scheduled content-scan recipe (cron + `pii_content_scan_enabled` var) as a
   documented pattern, not package code.
10. Snowflake content/value scanning (currently BigQuery-only by design).

### Chameleon integration tail
9. Set `PII_REGISTRY_DATASET_ID` on Key Vault prod so the dbt slice of the
   federated registry goes live (dbt prod target must materialize into
   `chameleon_prod` first).
