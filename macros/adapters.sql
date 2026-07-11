{#-
  Cross-warehouse SQL, isolated behind adapter.dispatch. Everything else in the
  metadata plane (registry, lineage, readiness, report) is portable dbt/Jinja.

  Supported: BigQuery (primary), Snowflake. The default__ implementations use
  the Snowflake-style forms, which also match most other warehouses
  (REGEXP_INSTR, a single database-wide information_schema) — but only the two
  named adapters are tested.

  Note on patterns: `pii_name_patterns` regexes are kept to the portable subset
  (alternation, anchors, character classes). Avoid backslash escapes like \d —
  they are not quoted identically across warehouses.
-#}

{#- Partial-match regex test (BigQuery regexp_contains semantics). -#}
{% macro pii_regexp(subject, pattern) %}
  {{ return(adapter.dispatch('pii_regexp', 'chameleon_pii')(subject, pattern)) }}
{% endmacro %}

{% macro bigquery__pii_regexp(subject, pattern) -%}
regexp_contains({{ subject }}, r'{{ pattern }}')
{%- endmacro %}

{% macro snowflake__pii_regexp(subject, pattern) -%}
regexp_instr({{ subject }}, '{{ pattern }}') > 0
{%- endmacro %}

{% macro default__pii_regexp(subject, pattern) -%}
regexp_instr({{ subject }}, '{{ pattern }}') > 0
{%- endmacro %}

{#-
  All column names across the configured datasets/schemas, as a subquery body
  yielding (table_schema, table_name, column_name). BigQuery scopes
  INFORMATION_SCHEMA per dataset, so it unions one select per dataset;
  Snowflake has one database-wide information_schema, so it filters — and
  lowercases, since Snowflake stores unquoted identifiers uppercase while the
  dbt graph (and BigQuery) use lowercase.
-#}
{% macro pii_information_schema_columns(datasets) %}
  {{ return(adapter.dispatch('pii_information_schema_columns', 'chameleon_pii')(datasets)) }}
{% endmacro %}

{% macro bigquery__pii_information_schema_columns(datasets) %}
  {%- for ds in datasets %}
  select '{{ ds }}' as table_schema, table_name, column_name
  from `{{ target.project }}.{{ ds }}.INFORMATION_SCHEMA.COLUMNS`
  {%- if not loop.last %}
  union all
  {%- endif %}
  {%- endfor %}
{% endmacro %}

{% macro snowflake__pii_information_schema_columns(datasets) %}
  select
    lower(table_schema) as table_schema,
    lower(table_name) as table_name,
    lower(column_name) as column_name
  from {{ target.database }}.information_schema.columns
  where lower(table_schema) in (
    {%- for ds in datasets %}'{{ ds | lower }}'{% if not loop.last %}, {% endif %}{% endfor -%}
  )
{% endmacro %}

{% macro default__pii_information_schema_columns(datasets) %}
  {{ chameleon_pii.snowflake__pii_information_schema_columns(datasets) }}
{% endmacro %}
