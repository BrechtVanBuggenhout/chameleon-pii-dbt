-- Real SQL-injection risk, found and fixed after Stage 2 first shipped: a
-- discovered JSON path comes from a real key in sampled row DATA, not a
-- compile-time-known identifier, and was being spliced unescaped into a SQL
-- string literal. Fixing the escaping then surfaced a second, deeper issue:
-- BigQuery's JSON_VALUE/JSON_QUERY don't support quoted bracket-notation keys
-- at all (confirmed live), so a key with a special character can never be
-- looked up via a path argument, escaped or not -- it has to be skipped for
-- path-level detection, not just safely escaped.
--
-- This fixture's key contains a literal quote. Two things must hold:
--  1. The model must build at all (a regression of either fix would either
--     break the generated SQL outright, or throw "Invalid token in JSONPath"
--     at query time -- this whole test file failing to even run is itself
--     a signal).
--  2. No PATH-LEVEL finding should exist for this unsafe key (proving the
--     safety filter actually skips it, rather than silently emitting a
--     malformed path) -- the whole-blob scan still catches the same email
--     coarsely, covered by the existing match-count assertions.
-- BigQuery-only: pii_content_findings is an intentionally empty shell on
-- other adapters (see macros/scan_content.sql), so skip this assertion there.
{{ config(enabled = (target.type == 'bigquery')) }}
select 'unsafe JSON key leaked into a path-level finding: ' || json_path as failure
from {{ ref('pii_content_findings') }}
where table_name = 'stg_ci_json_path_probe' and column_name = 'payload'
  and json_path is not null
  and json_path like '%\'%'
