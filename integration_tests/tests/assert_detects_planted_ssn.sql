-- Content scan must catch the SSN planted in the free-text notes column.
with check_ as (select 1 as x)
select 'notes SSN not detected by content scan' as failure
from check_
where not exists (
  select 1 from {{ ref('pii_content_findings') }}
  where table_name = 'pii_ci_customers' and column_name = 'notes' and pattern = 'SSN'
)
