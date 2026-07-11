{{ config(materialized='table') }}

{#-
  The flat PII registry: one row per (model, PII field). Built from graph
  metadata — declared `meta.pii` plus name inference — and, when
  `pii_auto_register_discovered` is on (default), the INFORMATION_SCHEMA
  discovery findings as well, so a zero-config install still yields a
  populated registry. Auto-registered rows carry
  detection_method = 'INFORMATION_SCHEMA' and never override declarations
  (discovery already excludes declared columns), and they do NOT silence
  the `no_undeclared_pii` test or the UNREGISTERED readiness verdict —
  those stay anchored to declarations.
-#}

{%- set rows = chameleon_pii.get_pii_columns() -%}
{%- set auto_register = var('pii_auto_register_discovered', true) and var('pii_discovery_enabled', true) -%}

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
  limit 0
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

{%- if auto_register %}
, discovered as (
  select
    resource_id,
    table_name as model_name,
    '{{ target.type }}' as system,
    case
      when regexp_contains(table_name, r'^stg_') then 'STAGING'
      when regexp_contains(table_name, r'^int_') then 'INTERMEDIATE'
      when regexp_contains(table_name, r'^(dim_|mart_|fct_)') then 'MART'
      when regexp_contains(table_name, r'^raw_') then 'RAW'
      else 'UNKNOWN'
    end as resource_layer,
    'discovery' as owner,
    field_name,
    classification,
    cast(null as {{ dbt.type_string() }}) as handling,
    confidence,
    detection_method,
    false as required_in_mart
  from {{ ref('pii_discovery') }}
)
{%- endif %}

, combined as (
  select * from registry
{%- if auto_register %}
  union all
  select * from discovered
{%- endif %}
)

select
  combined.*,
  '{{ var("registry_version", run_started_at.strftime("%Y-%m-%d")) }}' as registry_version,
  cast('{{ run_started_at }}' as {{ dbt.type_timestamp() }}) as detected_at
from combined
