{{ config(schema='decrypted_views_ci') }}

{#-
  Stands in for chameleon-key-vault's decrypted_views dataset: a table that
  would be flagged instantly by discovery for its 'email' column name if it
  sat in a scanned dataset. The `schema` config above puts it in its own
  dataset (`<target schema>_decrypted_views_ci` on BigQuery) rather than the
  target schema `pii_discovery_datasets` defaults to -- proving the
  separation is structural (a dataset discovery never even looks at), not
  "nobody's declared it yet" within a dataset that IS scanned. See
  assert_decrypted_views_dataset_invisible_to_discovery.sql.
-#}
select customer_id, email
from {{ ref('pii_ci_customers') }}
