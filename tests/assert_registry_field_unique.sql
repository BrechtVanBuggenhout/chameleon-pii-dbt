-- Each (resource_id, field_name) should appear at most once in the registry.
select resource_id, field_name, count(*) as n
from {{ ref('pii_registry') }}
group by resource_id, field_name
having count(*) > 1
