-- Match count can never exceed the number of rows sampled.
select *
from {{ ref('pii_content_findings') }}
where match_count > sampled_rows
