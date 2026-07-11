{{ config(materialized='table') }}

{#-
  Undeclared-PII discovery. Reads column NAMES from INFORMATION_SCHEMA.COLUMNS across
  the configured datasets and flags those that look like PII by name but are NOT
  declared via `meta.pii`. This is the metadata plane: it reads column names, not row
  values — a cheap metadata query, not a content scan.

  Output is the gap the registry can't see: PII-looking columns nobody documented.
  Feeds the (roadmap) `expect_no_undeclared_pii` test.
-#}

{%- set discovery_enabled = var('pii_discovery_enabled', true) -%}
{%- set datasets = var('pii_discovery_datasets', [target.schema]) -%}
{%- set declared = chameleon_pii.get_pii_columns() -%}

{%- if not discovery_enabled %}
select
  cast(null as {{ dbt.type_string() }}) as resource_id,
  cast(null as {{ dbt.type_string() }}) as table_schema,
  cast(null as {{ dbt.type_string() }}) as table_name,
  cast(null as {{ dbt.type_string() }}) as field_name,
  cast(null as {{ dbt.type_string() }}) as classification,
  cast(null as {{ dbt.type_string() }}) as confidence,
  cast(null as {{ dbt.type_string() }}) as detection_method,
  cast(null as {{ dbt.type_timestamp() }}) as discovered_at
limit 0
{%- else %}

with all_columns as (
  {{ chameleon_pii.pii_information_schema_columns(datasets) }}
),

declared as (
  {%- if declared | length == 0 %}
  select cast(null as {{ dbt.type_string() }}) as table_name, cast(null as {{ dbt.type_string() }}) as column_name
  limit 0
  {%- else %}
  {%- for d in declared %}
  select '{{ d.model_name | replace("'", "''") }}' as table_name, '{{ d.field_name | replace("'", "''") }}' as column_name
  {%- if not loop.last %}
  union all
  {%- endif %}
  {%- endfor %}
  {%- endif %}
),

matched as (
  select
    table_schema,
    table_name,
    column_name,
    {{ chameleon_pii.pii_name_case('column_name') }} as classification
  from all_columns
  -- never flag the package's own output tables
  where table_name not in (
    'pii_registry', 'pii_field_lineage', 'pii_discovery', 'pii_shred_readiness', 'pii_content_findings'
  )
)

select
  {#- target.database == target.project on BigQuery; portable elsewhere -#}
  '{{ target.type }}:' || '{{ target.database }}' || '.' || m.table_schema || '.' || m.table_name as resource_id,
  m.table_schema,
  m.table_name,
  m.column_name as field_name,
  m.classification,
  '{{ var("pii_inference_confidence", "INFERRED_HIGH") }}' as confidence,
  'INFORMATION_SCHEMA' as detection_method,
  current_timestamp() as discovered_at
from matched m
where m.classification is not null
  and not exists (
    select 1 from declared d
    where d.table_name = m.table_name
      and d.column_name = m.column_name
  )
{%- endif %}
