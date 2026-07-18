-- Content scan must catch the SSN planted in the free-text notes column.
-- BigQuery-only: pii_content_findings is an intentionally empty shell on
-- other adapters (see macros/scan_content.sql), so skip this assertion there.
{{ config(enabled = (target.type == 'bigquery')) }}
with check_ as (select 1 as x)
select 'notes SSN not detected by content scan' as failure
from check_
where not exists (
  select 1 from {{ ref('pii_content_findings') }}
  where table_name = 'pii_ci_customers' and column_name = 'notes' and pattern = 'SSN'
)
