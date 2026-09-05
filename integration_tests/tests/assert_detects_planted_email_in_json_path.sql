-- Stage 2: content scan must produce a path-level finding (json_path populated)
-- for an email nested two levels deep in a JSON column, not just the whole-blob
-- finding Stage 1 already produces.
-- BigQuery-only: pii_content_findings is an intentionally empty shell on
-- other adapters (see macros/scan_content.sql), so skip this assertion there.
{{ config(enabled = (target.type == 'bigquery')) }}
with check_ as (select 1 as x)
select 'nested EMAIL in JSON payload not detected at path level' as failure
from check_
where not exists (
  select 1 from {{ ref('pii_content_findings') }}
  where table_name = 'stg_ci_json_path_probe' and column_name = 'payload'
    and source_data_type = 'JSON' and pattern = 'EMAIL'
    and json_path = '$.profile.contact.work_email'
)
