# chameleon_pii — project log

What has shipped, what state the package is in, and what comes next.
(Newest release last; see git tags for exact code.)

## Status — 2026-07-09

**Feature-complete** for the BigQuery-only v0 scope. Five models, 22 ride-along
tests, CI with keyless (WIF) auth against a dedicated `chameleon_pii_ci` dataset.
Pinned at `v0.7.0` by the consuming project (`chameleon-dataplatform-dbt`).
Also feeds Chameleon's Key Vault registry (federated: connector + dbt + manual
slices; dbt slice activates when `PII_REGISTRY_DATASET_ID` is set).

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
1. **Finish CI activation**: add the 3 GitHub Actions *variables* on this repo —
   `GCP_PROJECT=chameleon-dev-496718`,
   `GCP_DBT_SA=chameleon-dbt-dev@chameleon-dev-496718.iam.gserviceaccount.com`,
   `GCP_WIF_PROVIDER=projects/1075733109023/locations/global/workloadIdentityPools/github-actions-dev-pool/providers/github-provider`
   — then trigger the workflow once to confirm green.
2. **Make the repo public** and submit to **dbt Hub** (public repos only).
3. **Launch write-up**: "we found PII leaking into our mart layer with zero
   bytes scanned" — the `email_token` → `dim_users` story, metadata-plane
   design, shred-readiness verdicts. Link it from chameleon-data.com
   (the /learn cluster is the natural home) and post where data engineers read.
4. Add a README badge for CI + a short GIF/screenshot of `pii_shred_readiness`
   output.

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
