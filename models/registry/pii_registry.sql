{{ config(materialized='table') }}

{#-
  The flat PII registry: one row per (model, PII field). Built entirely from
  graph metadata — declared `meta.pii` plus name inference. No warehouse scan.
-#}

{%- set rows = chameleon_pii.get_pii_columns() -%}

with registry as (
{%- if rows | length == 0 %}
  select
    cast(null as {{ dbt.type_string() }}) as resource_id,
    cast(null as {{ dbt.type_string() }}) as model_name,
    cast(null as {{ dbt.type_string() }}) as system,
    cast(null as {{ dbt.type_string() }}) as resource_layer,
    cast(null as {{ dbt.type_string() }}) as owner,
    cast(null as {{ dbt.type_string() }}) as field_name,
    cast(null as {{ dbt.type_string() }}) as classification,
    cast(null as {{ dbt.type_string() }}) as handling,
    cast(null as {{ dbt.type_string() }}) as confidence,
    cast(null as {{ dbt.type_string() }}) as detection_method,
    cast(null as boolean) as required_in_mart
  where 1 = 0
{%- else %}
{%- for r in rows %}
  select
    '{{ r.resource_id | replace("'", "''") }}' as resource_id,
    '{{ r.model_name | replace("'", "''") }}' as model_name,
    '{{ r.system }}' as system,
    '{{ r.layer }}' as resource_layer,
    '{{ r.owner | replace("'", "''") }}' as owner,
    '{{ r.field_name | replace("'", "''") }}' as field_name,
    '{{ r.classification }}' as classification,
    '{{ r.handling }}' as handling,
    '{{ r.confidence }}' as confidence,
    '{{ r.detection_method }}' as detection_method,
    {{ r.required_in_mart | lower }} as required_in_mart
{%- if not loop.last %}
  union all
{%- endif %}
{%- endfor %}
{%- endif %}
)

select
  registry.*,
  '{{ var("registry_version", run_started_at.strftime("%Y-%m-%d")) }}' as registry_version,
  cast('{{ run_started_at }}' as {{ dbt.type_timestamp() }}) as detected_at
from registry
