# chameleon_pii

A dbt package that **finds your PII and maps where it flows — with zero configuration
and zero bytes scanned.** Install it, build it, and it flags every PII-looking column
in your warehouse (email, phone, SSN, names, addresses, …), builds a registry and a
field-level lineage map, and tells you which fields could actually be erased on a
deletion request. No YAML required to get your first findings.

It is **metadata-first by design**: detection and lineage read the dbt graph and
`INFORMATION_SCHEMA` — not your rows — so the core models bill zero to near-zero
bytes and are safe on every build. Value-level scanning exists as a separate,
opt-in, scheduled layer.

> **Warehouse support:** BigQuery only for now. The models use BigQuery-specific SQL
> (`INFORMATION_SCHEMA`, `TABLESAMPLE`, `regexp_contains`).

## Quick start (zero config)

```yaml
# packages.yml
packages:
  - git: "https://github.com/BrechtVanBuggenhout/chameleon-pii-dbt.git"
    revision: "v0.8.0"
```

```bash
dbt deps
dbt build                          # your models (so the scanners have tables to read)
dbt build --select package:chameleon_pii
dbt run-operation pii_report
```

That last command prints what was found, right in your terminal:

```text
──────────────────────────────────────────────────────────────
 chameleon_pii report — bigquery:my-project.analytics
──────────────────────────────────────────────────────────────
 Registry     5 PII field(s) across 3 table(s)
              1 declared · 0 name-inferred · 4 auto-registered from discovery
 Lineage      1 downstream flow(s), deepest path 1 hop(s)
 Readiness    READY 1 · AT_RISK 0 · NOT_SHREDDABLE 0 · UNREGISTERED 4

 Undeclared PII:
   ! dim_users.email_token (DIRECT_IDENTIFIER) — reaches mart
   • raw_users.email_token (DIRECT_IDENTIFIER)
   • raw_users.subscription_name (DIRECT_IDENTIFIER)
 Content scan off (set pii_content_scan_enabled: true to sample values)
──────────────────────────────────────────────────────────────
```

Out of the box, discovery matches column names across your target dataset against
built-in patterns (email, phone, SSN, date of birth, names, addresses, IP, passport /
national id, card / account numbers) and auto-registers what it finds
(`pii_auto_register_discovered: true`), so the registry is populated before you write
a single line of YAML. Declarations (below) are how you *confirm or correct* what the
machine inferred — auto-registered findings still count as undeclared for the
`no_undeclared_pii` test until you do.

## What you get

Five ordinary dbt models, materialized in your own warehouse — nothing leaves it:

- `pii_registry` — one row per (table, PII field): classification, handling, confidence,
  and how it was detected (declared / name-inferred / discovered).
- `pii_field_lineage` — the "used where" map: every downstream model each PII field reaches.
- `pii_discovery` — undeclared PII: columns that look like PII by name (read from
  `INFORMATION_SCHEMA`) but were never declared via `meta.pii`. This catches PII in
  tables you never documented, including raw sources and leaks into mart layers.
- `pii_shred_readiness` — per-field verdict (READY / AT_RISK / NOT_SHREDDABLE /
  UNREGISTERED): can this PII actually be crypto-shredded, and where does it escape to?
- `pii_content_findings` — PII found by scanning column *values*, not names (off by
  default; the expensive data plane).

Plus the `no_undeclared_pii` test: warn locally, fail the build in CI when someone
ships a PII column nobody declared.

## Declare PII

Declarations turn a machine guess into a governed fact: they set the handling policy,
flip the field's confidence to `DECLARED`, and clear it from the undeclared queue.
Tag columns in any `schema.yml` with `meta.pii`:

```yaml
models:
  - name: stg_users
    columns:
      - name: email
        meta:
          pii:
            classification: DIRECT_IDENTIFIER
            handling: ENCRYPT          # optional — defaulted from classification
      - name: phone
        meta:
          pii:
            classification: CONTACT
```

Optional model-level metadata:

```yaml
    meta:
      chameleon:
        layer: STAGING   # RAW | STAGING | INTERMEDIATE | MART (else inferred from path)
        owner: dbt       # who owns the resource
```

Anything you don't declare is still caught by **name inference** (configurable via
`vars: pii_name_patterns`) and recorded with `confidence = INFERRED_HIGH`, so you can
review and promote it to a declaration.

## Build

```bash
dbt build --select chameleon_pii
```

## Configure

```yaml
# dbt_project.yml
vars:
  pii_inference_enabled: true
  pii_inference_confidence: INFERRED_HIGH
  pii_name_patterns:
    "(^|_)email(_|$)": DIRECT_IDENTIFIER
    # add your own column-name → classification rules
```

## How it works

| Plane | Cost | When |
|-------|------|------|
| Declare — `meta.pii` + name inference | free (graph only) | every build |
| Propagate — DAG walk → `pii_field_lineage` | free (graph only) | every build |
| Discover — `INFORMATION_SCHEMA` name scan → `pii_discovery` | cheap (metadata query, names not values) | every build |
| Scan — sample column *values* → `pii_content_findings` | warehouse cost (sampled + capped) | scheduled, off by default |

### Discovery

`pii_discovery` reads column **names** from `INFORMATION_SCHEMA.COLUMNS` across the
configured datasets and flags any that match a PII name pattern but are not declared.
It reads names, not row values, so it stays in the metadata plane. Configure it with:

```yaml
vars:
  pii_discovery_enabled: true
  pii_discovery_datasets: ["analytics", "raw"]   # defaults to the target dataset
```

Discovery is high-recall by design: a column called `subscription_name` will match the
`name` pattern even though it is not a person's name. Findings are `INFERRED` candidates
to review — promote the real ones to `meta.pii` declarations, and tune `pii_name_patterns`
to cut noise.

### Content scanning

`pii_content_findings` inspects actual column **values** to catch PII that names don't
reveal — an email inside a free-text `notes` column, a phone in `description`. It is the
expensive data plane, so it is **off by default** and built to run on a schedule:

```yaml
vars:
  pii_content_scan_enabled: true          # off by default
  pii_content_sample_percent: 10          # TABLESAMPLE percent (base tables only)
  pii_content_max_bytes_billed: 1000000000  # 1 GB cap per scan
  # pii_content_scan_datasets: ["analytics", "raw"]
  # pii_value_patterns: {...}             # override the value regexes
```

It scans only name-innocent STRING columns (declared / name-matching columns are already
covered by the registry + discovery), one sampled pass per table. Run it deliberately:
`dbt build --select pii_content_findings`.

## Build order

`pii_registry` and `pii_field_lineage` read the dbt graph (metadata), so their order
doesn't matter. But `pii_discovery` and `pii_content_findings` read `INFORMATION_SCHEMA`
/ table values, so **they must run after the models they scan exist.** On a fresh build
(or `--full-refresh`), run your models first, then the package:

```bash
dbt build --exclude package:chameleon_pii   # your models
dbt build --select package:chameleon_pii    # then the scanners
```

On a warm warehouse (tables already present) a single `dbt build` is fine.

## Tests

The package ships assertions that run on any `dbt build`/`dbt test`: `accepted_values`
on the classification / confidence / detection-method / pattern / readiness enums,
`not_null` on key columns, and singular invariant tests (lineage hops >= 1, content
`match_count <= sampled_rows`, unique `(resource_id, field_name)` in the registry). The
`no_undeclared_pii` test warns by default (see above).

## Roadmap

- `pii_scan_events` — append-only change log written only on diffs.
- Schema-hash cache — skip re-scanning unchanged tables.
- Column-rename-aware lineage propagation.
- `publish_registry` run-operation — push the registry to an external control plane
  (e.g. the Chameleon Key Vault).
