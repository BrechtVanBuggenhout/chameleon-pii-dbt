# chameleon_pii

A dbt package that **automatically flags PII columns and builds a registry** of where
sensitive data lives and where it flows — directly inside your dbt project.

You declare PII once (or let the package infer it from column names), run `dbt build`,
and you get two tables in your own warehouse:

- `pii_registry` — one row per (model, PII field): classification, handling, confidence.
- `pii_field_lineage` — the "used where" map: every downstream model each PII field reaches.

It is **metadata-first and performant by design**: detection and lineage read the dbt
graph only and issue zero warehouse queries, so they are safe to run on every build.
(Content sampling — scanning actual values to find *undeclared* PII — is a separate,
opt-in, scheduled layer; see roadmap.)

## Install

In your project's `packages.yml`:

```yaml
packages:
  - git: "https://github.com/chameleon-data/chameleon-pii-dbt.git"
    revision: "0.1.0"
```

Then `dbt deps`.

## Declare PII

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
| Scan — sample column values for undeclared PII | warehouse cost | scheduled (roadmap) |

## Roadmap

- `pii_scan_findings` — sampled content scan (TABLESAMPLE, schema-hash cache, byte caps).
- `pii_scan_events` — append-only change log written only on diffs.
- `expect_no_undeclared_pii` — generic test to fail CI on undeclared PII.
- `information_schema` discovery — name inference over *undocumented* columns.
- Column-rename-aware lineage propagation.
- `publish_registry` run-operation — push the registry to an external control plane
  (e.g. the Chameleon Key Vault).
