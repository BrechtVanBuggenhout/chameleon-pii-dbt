-- A lineage edge is a downstream hop, so hops must be >= 1.
select *
from {{ ref('pii_field_lineage') }}
where hops < 1
