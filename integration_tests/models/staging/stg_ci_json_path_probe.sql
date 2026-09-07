{{ config(materialized='table') }}

-- CI fixture for Stage 2 path-level JSON content scanning. `payload` is a real
-- BigQuery JSON column, undeclared/name-innocent. Row p1 nests an email two levels
-- deep (exercises the plain scalar-path case). Row p2 puts a planted email inside
-- one element of an array of contact objects (exercises the array-unnest case --
-- the specific gap Stage 2 closes: JSON_KEYS collapses array elements to one
-- generic path, so a naive path-level scan would silently miss this). Row p3 is a
-- benign control with an array of plain-string tags (scalar-array case, no PII).
-- Row p4's key contains a literal single quote -- discovered paths come from real
-- JSON keys in sampled row DATA, not a compile-time-known identifier, so a quote
-- here must not break the generated SQL (a real SQL-injection risk, found and
-- fixed after Stage 2 first shipped -- see scan_content.sql's path_safe/
-- element_path_safe escaping).
select * from unnest([
  struct('p1' as probe_id, JSON '{"profile":{"contact":{"work_email":"nested+json@example.com"}}}' as payload),
  struct('p2' as probe_id, JSON '{"contacts":[{"email":"planted-in-array@example.com","label":"home"},{"email":"clean-label@example.com","label":"work"}]}' as payload),
  struct('p3' as probe_id, JSON '{"tags":["newsletter","beta"],"note":"nothing sensitive here"}' as payload),
  struct('p4' as probe_id, JSON '{"user\'s_email":"quote-key-planted@example.com"}' as payload)
])
