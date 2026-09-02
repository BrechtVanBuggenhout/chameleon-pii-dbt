{{ config(materialized='table') }}

-- CI fixture for JSON content scanning. Must be a real BASE TABLE, not the
-- project's default view materialization, since get_content_scan_candidates
-- requires table_type = 'BASE TABLE'. `payload` is intentionally undeclared
-- (no pii_registry entry, no PII-suggestive column name) so it's only ever
-- caught by content scanning, never by name-based discovery -- exercises
-- exactly the gap Stage 1 closes.
select * from unnest([
  struct('j1' as probe_id, JSON '{"contact":{"backup_email":"leaked+json@example.com"},"note":"called re: invoice"}' as payload),
  struct('j2' as probe_id, JSON '{"ssn_on_file":"123-45-6789","verified":true}' as payload),
  struct('j3' as probe_id, JSON '{"note":"nothing sensitive here"}' as payload)
])
