-- dim_ci_customers carries the declared, ENCRYPT-handled `email` field forward
-- from staging (see marts/dim_ci_customers.sql) -- exercises the "PII with a
-- crypto anchor still leaked into a mart" path shred-readiness exists for.
with check_ as (select 1 as x)
select 'dim_ci_customers.email not flagged AT_RISK/reaches_mart by shred-readiness' as failure
from check_
where not exists (
  select 1 from {{ ref('pii_shred_readiness') }}
  where table_name = 'dim_ci_customers'
    and field_name = 'email'
    and readiness = 'AT_RISK'
    and reaches_mart
)
