select customer_id, email, phone, full_name, plan, notes
from {{ ref('pii_ci_customers') }}
