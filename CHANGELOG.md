# chameleon_pii — project log

What has shipped, what state the package is in, and what comes next.
(Newest release last; see git tags for exact code.)

## Status — 2026-08-01

**Feature-complete, PUBLIC, and cross-warehouse** (repo public 2026-07-09, CI green,
launch post live at chameleon-data.com/learn/dbt-pii-package). Five models, tests
riding on `dbt build`, CI with keyless (WIF) auth against a dedicated
`chameleon_pii_ci` BigQuery dataset. Snowflake support verified end-to-end
2026-07-18 against a real trial account. Also feeds Chameleon's Key Vault registry
(federated: connector + dbt + manual slices; dbt slice activates when
`PII_REGISTRY_DATASET_ID` is set).

`pii_shred_readiness`'s verdicts are now enforceable, not just reportable
(`assert_no_shred_risk_reaching_marts`, v1.1.0) -- closes the gap found while
auditing `chameleon-dataplatform-dbt` (Chameleon's own real dbt project): it
already had `no_undeclared_pii` wired up, but only at `warn`, and nothing
enforced shred-readiness at all. Pinned at `v0.9.0` there as of this writing;
upgrading it to pick up v1.1.0 and turning both severities to `error` is the
natural next step, tracked separately in that repo.

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
| v1.0.0 | **Declaring the package stable.** No functional changes from v0.9.0 — this marks the package production-ready per dbt's own Semantic Versioning guidance, now that it's feature-complete, cross-warehouse verified, licensed (Apache 2.0), and checked against dbt Hub's package best-practices doc ahead of submission. (Also fixes `dbt_project.yml`'s `version` field, which had drifted to `0.8.0` and was never bumped for the v0.9.0 release.) |
| v1.1.0 | `assert_no_shred_risk_reaching_marts` — the enforcement step `pii_shred_readiness` was missing since v0.3.0: fails when a field is AT_RISK/NOT_SHREDDABLE/UNREGISTERED *and* reaches a mart/aggregate layer, same `warn`-by-default/`pii_shred_risk_severity: error`-to-enforce convention as `no_undeclared_pii`. |
| v1.2.0 | Three fixes, found running the package against a real multi-project warehouse: (1) `pii_name_exclude_patterns` — vetoes a `pii_name_patterns` match before it fires, with defaults covering metric-shaped fields (`metrics_phone_impressions`, `metrics_phone_through_rate`) and non-person `*_name` dimensions (`event_name`, `ad_group_name`); false positives on those no longer show up as high-risk. (2) `pii_discovered_datasets()` / `dbt run-operation pii_list_datasets` — `pii_discovery_datasets`/`pii_content_scan_datasets` are now optional, inferred from every `source()` schema across the project's `sources.yml` files plus every model's schema, instead of a hand-maintained list someone has to keep in sync by grepping. (3) That inference (and `pii_information_schema_columns` under it) is cross-project-aware: a `source()` with a `database:` override pointing at a different GCP project/Snowflake database is discovered and scanned in *that* project, not silently queried against the target project. `pii_discovery`/`pii_content_findings` now carry a `table_catalog` column and `pii_report`'s undeclared-findings list prints the full `type:project.dataset.table.field` per finding, so it's unambiguous which project a finding lives in even when datasets span projects. Broadening auto-discovery to every model's schema also broke `assert_decrypted_views_dataset_invisible_to_discovery` (added on `main` after this branched, caught by CI) — a decrypted-views-style dataset is now reachable the same as any other schema unless explicitly carved out, so `pii_discovery_exclude_dataset_patterns` was added alongside it: regex-matched, applied only to the inferred default (an explicit `pii_discovery_datasets` list is never filtered), and end-anchored so it survives whatever the target schema (and therefore a custom-schema-suffixed dataset name) resolves to per environment. |

## Known limitations

- Value-level content scanning (`pii_content_findings`) is **BigQuery only**;
  builds an empty portable-typed table on Snowflake and other adapters.
- Graph-based models only see columns documented in `schema.yml`; discovery
  fills the gap via INFORMATION_SCHEMA but fuller lineage needs catalog.json.
- Fresh `dbt build` runs discovery/content scans before target models exist →
  two-phase build documented in README; no dependency edge can express it.
- Name patterns are still deliberately high-recall — `pii_name_exclude_patterns`
  (v1.2.0) covers the common metric/dimension false-positive shapes by default,
  but a genuinely ambiguous company-specific field name (e.g. `subscription_name`)
  can still need a manual addition to that var; tune via vars, review findings.
- `pii_discovered_datasets()` (v1.2.0) only sees schemas reachable from the dbt
  graph (source()s + models). A raw dataset nobody has declared a source() for
  and no model reads from is invisible to auto-discovery; add it to
  `pii_discovery_datasets` explicitly if it needs scanning too.

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
