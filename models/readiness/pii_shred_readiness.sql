{{ config(materialized='table') }}

{#-
  Shred-readiness: can each PII field actually be crypto-shredded, and where does it
  escape to? Combines the declared registry, the discovered (undeclared) columns, and
  the downstream lineage into one verdict per field.

  readiness:
    READY          - declared with a crypto anchor (encrypt/tokenize/surrogate),
                     does not escape into a mart/aggregate layer.
    AT_RISK        - declared + shreddable, but reaches a mart/aggregate layer where
                     row-level shredding may not propagate.
    NOT_SHREDDABLE - declared but handled without a crypto anchor (redact / manual /
                     aggregate-only); crypto-shred does not apply.
    UNREGISTERED   - discovered PII with no declaration or strategy at all (highest risk).
-#}

with declared as (
  select
    resource_id,
    model_name as table_name,
    resource_layer,
    field_name,
    classification,
    handling,
    'DECLARED' as source
  from {{ ref('pii_registry') }}
  -- Auto-registered discovery rows (detection_method = INFORMATION_SCHEMA) are
  -- visibility entries, not governance sign-off: they stay on the DISCOVERED
  -- branch below so their verdict remains UNREGISTERED.
  where detection_method in ('DECLARED', 'NAME_INFERENCE')
),

discovered as (
  select
    resource_id,
    table_name,
    case
      when {{ chameleon_pii.pii_regexp('table_name', '^stg_') }} then 'STAGING'
      when {{ chameleon_pii.pii_regexp('table_name', '^int_') }} then 'INTERMEDIATE'
      when {{ chameleon_pii.pii_regexp('table_name', '^(dim_|mart_|fct_)') }} then 'MART'
      when {{ chameleon_pii.pii_regexp('table_name', '^raw_') }} then 'RAW'
      else 'UNKNOWN'
    end as resource_layer,
    field_name,
    classification,
    cast(null as {{ dbt.type_string() }}) as handling,
    'DISCOVERED' as source
  from {{ ref('pii_discovery') }}
),

combined as (
  select * from declared
  union all
  select * from discovered
),

lineage_rollup as (
  select
    source_resource_id,
    field_name,
    count(*) as downstream_count,
    max(case when {{ chameleon_pii.pii_regexp('downstream_model', '^(dim_|mart_|fct_)') }} then 1 else 0 end) as reaches_mart_lineage
  from {{ ref('pii_field_lineage') }}
  group by 1, 2
)

select
  c.resource_id,
  c.table_name,
  c.resource_layer,
  c.field_name,
  c.classification,
  c.handling,
  c.source,
  coalesce(l.downstream_count, 0) as downstream_count,
  c.handling in ('ENCRYPT', 'TOKENIZE', 'HASH_SURROGATE') as has_crypto_anchor,
  (c.resource_layer = 'MART' or coalesce(l.reaches_mart_lineage, 0) = 1) as reaches_mart,
  case
    when c.source = 'DISCOVERED' then 'UNREGISTERED'
    when c.handling in ('ENCRYPT', 'TOKENIZE', 'HASH_SURROGATE')
      and not (c.resource_layer = 'MART' or coalesce(l.reaches_mart_lineage, 0) = 1) then 'READY'
    when c.handling in ('ENCRYPT', 'TOKENIZE', 'HASH_SURROGATE') then 'AT_RISK'
    else 'NOT_SHREDDABLE'
  end as readiness,
  trim(concat(
    case when c.source = 'DISCOVERED' then 'undeclared PII; ' else '' end,
    case when c.source = 'DECLARED' and c.handling not in ('ENCRYPT', 'TOKENIZE', 'HASH_SURROGATE')
      then 'no crypto anchor; ' else '' end,
    case when (c.resource_layer = 'MART' or coalesce(l.reaches_mart_lineage, 0) = 1)
      then 'reaches mart/aggregate; ' else '' end,
    case when coalesce(l.downstream_count, 0) > 0
      then concat('flows to ', cast(l.downstream_count as {{ dbt.type_string() }}), ' downstream model(s); ') else '' end
  )) as reasons,
  current_timestamp() as assessed_at
from combined c
left join lineage_rollup l
  on l.source_resource_id = c.resource_id
  and l.field_name = c.field_name
