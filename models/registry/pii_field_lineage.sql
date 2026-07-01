{{ config(materialized='table') }}

{#-
  The "used where" map: every downstream model.column a PII field flows into,
  propagated through the dbt DAG. Pure metadata — bounded by DAG size, not row count.
-#}

{%- set edges = chameleon_pii.get_pii_lineage() -%}

{%- if edges | length == 0 %}
select
  cast(null as {{ dbt.type_string() }}) as source_resource_id,
  cast(null as {{ dbt.type_string() }}) as field_name,
  cast(null as {{ dbt.type_string() }}) as classification,
  cast(null as {{ dbt.type_string() }}) as downstream_resource_id,
  cast(null as {{ dbt.type_string() }}) as downstream_model,
  cast(null as {{ dbt.type_string() }}) as downstream_field,
  cast(null as {{ dbt.type_int() }}) as hops
limit 0
{%- else %}
{%- for e in edges %}
select
  '{{ e.source_resource_id | replace("'", "''") }}' as source_resource_id,
  '{{ e.field_name | replace("'", "''") }}' as field_name,
  '{{ e.classification }}' as classification,
  '{{ e.downstream_resource_id | replace("'", "''") }}' as downstream_resource_id,
  '{{ e.downstream_model | replace("'", "''") }}' as downstream_model,
  '{{ e.downstream_field | replace("'", "''") }}' as downstream_field,
  {{ e.hops }} as hops
{%- if not loop.last %}
union all
{%- endif %}
{%- endfor %}
{%- endif %}
