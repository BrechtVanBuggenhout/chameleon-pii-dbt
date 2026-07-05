-- Carries email forward into a mart-layer model -> exercises the "PII leaked into a
-- mart" path in discovery + shred-readiness.
select customer_id, email, plan
from {{ ref('stg_ci_customers') }}
