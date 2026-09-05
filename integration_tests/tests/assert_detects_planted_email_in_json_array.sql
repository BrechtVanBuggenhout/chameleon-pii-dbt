-- Stage 2's actual reason to exist: an email inside one element of an array of
-- objects (contacts[0].email) must still be found, even though JSON_KEYS collapses
-- array elements into one generic path with no index (confirmed live against real
-- BigQuery) -- a naive path-level implementation would silently miss this.
-- BigQuery-only: pii_content_findings is an intentionally empty shell on
-- other adapters (see macros/scan_content.sql), so skip this assertion there.
{{ config(enabled = (target.type == 'bigquery')) }}
with check_ as (select 1 as x)
select 'planted EMAIL inside array-of-objects not detected at path level' as failure
from check_
where not exists (
  select 1 from {{ ref('pii_content_findings') }}
  where table_name = 'stg_ci_json_path_probe' and column_name = 'payload'
    and source_data_type = 'JSON' and pattern = 'EMAIL'
    and json_path = '$.contacts[*].email'
)
