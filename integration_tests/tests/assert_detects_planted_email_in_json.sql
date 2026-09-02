-- Content scan must catch an email buried inside a nested key of a JSON
-- column, not just a top-level STRING column.
-- BigQuery-only: pii_content_findings is an intentionally empty shell on
-- other adapters (see macros/scan_content.sql), so skip this assertion there.
{{ config(enabled = (target.type == 'bigquery')) }}
with check_ as (select 1 as x)
select 'nested EMAIL in JSON payload not detected by content scan' as failure
from check_
where not exists (
  select 1 from {{ ref('pii_content_findings') }}
  where table_name = 'stg_ci_json_probe' and column_name = 'payload'
    and source_data_type = 'JSON' and pattern = 'EMAIL'
)
