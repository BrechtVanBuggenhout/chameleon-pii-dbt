# chameleon_pii — project log

What has shipped, what state the package is in, and what comes next.
(Newest release last; see git tags for exact code.)

## Status — 2026-07-11

**Feature-complete and PUBLIC** (repo public 2026-07-09, CI green, launch post live
at chameleon-data.com/learn/dbt-pii-package). Five models, 22 ride-along tests, CI
with keyless (WIF) auth against a dedicated `chameleon_pii_ci` dataset. Pinned at
`v0.8.0` by the consuming project (`chameleon-dataplatform-dbt`). Also feeds
Chameleon's Key Vault registry (federated: connector + dbt + manual slices; dbt
slice activates when `PII_REGISTRY_DATASET_ID` is set).

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

## Known limitations

- **BigQuery only** (INFORMATION_SCHEMA, TABLESAMPLE, `regexp_contains`).
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

### Product (build only when pulled by real users)
5. **Cross-warehouse** via `adapter.dispatch` — Snowflake first. This 5–10×es
   the addressable audience; port the metadata plane only (registry, lineage,
   discovery), leave content scanning BigQuery-only initially.
6. Resource-level policy knobs declared in dbt (`meta.chameleon`:
   deletionStrategy, user/tenant columns) instead of derived defaults in
   Key Vault's `BigQueryPiiRegistryRepository`.
7. `pii_scan_events` append-only diff log (cheap forever-history of findings).
8. Scheduled content-scan recipe (cron + `pii_content_scan_enabled` var) as a
   documented pattern, not package code.

### Chameleon integration tail
9. Set `PII_REGISTRY_DATASET_ID` on Key Vault prod so the dbt slice of the
   federated registry goes live (dbt prod target must materialize into
   `chameleon_prod` first).
