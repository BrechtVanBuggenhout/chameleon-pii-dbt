-- Name discovery must flag the undeclared full_name column.
with check_ as (select 1 as x)
select 'full_name not flagged by discovery' as failure
from check_
where not exists (
  select 1 from {{ ref('pii_discovery') }}
  where field_name = 'full_name'
)
