-- The scalar-array control row (tags: ["newsletter","beta"]) and the benign
-- "label"/"note" values in stg_ci_json_path_probe must not produce a spurious
-- path-level match -- JSON's own structural characters or the scalar-array
-- fallback path (element_path = '$') must not false-positive.
{{ config(enabled = (target.type == 'bigquery')) }}
select 'unexpected path-level pattern match on JSON payload: ' || json_path || ' / ' || pattern as failure
from {{ ref('pii_content_findings') }}
where table_name = 'stg_ci_json_path_probe' and column_name = 'payload'
  and json_path is not null
  and json_path not in ('$.profile.contact.work_email', '$.contacts[*].email')
