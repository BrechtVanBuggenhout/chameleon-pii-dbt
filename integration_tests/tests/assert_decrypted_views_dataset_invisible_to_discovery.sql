-- Decrypted-views-style datasets (chameleon-key-vault's decrypted_views,
-- stood in for here by decrypted_views_probe) must never surface in
-- pii_discovery, no matter how obviously PII-named their columns are --
-- the whole point of the decrypted-views feature is that this dataset sits
-- structurally outside pii_discovery_datasets, not merely undeclared within
-- one that IS scanned (that's a different, much weaker guarantee).
-- decrypted_views_probe has a column literally named 'email' and zero
-- meta.pii declarations of its own; if this test ever finds a row for it,
-- the dataset boundary discovery relies on has broken.
select 'decrypted_views_probe leaked into pii_discovery' as failure
from {{ ref('pii_discovery') }}
where table_name = 'decrypted_views_probe'
