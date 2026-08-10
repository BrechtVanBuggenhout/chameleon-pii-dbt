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
  Splits a dataset entry into (database, schema). Accepts a plain schema name
  ("analytics", implicitly under target.database) or a fully-qualified
  "database.schema" (what pii_discovered_datasets() emits, e.g. a source() that
  overrides `database:` to point at a different GCP project/Snowflake database).
  This is what makes cross-project discovery possible instead of every dataset
  silently being queried against target.database regardless of where it actually
  lives.
-#}
{% macro pii_split_dataset(ds) %}
  {%- set parts = ds.split('.') -%}
  {%- if parts | length > 1 -%}
    {{ return({'database': parts[0], 'schema': parts[1]}) }}
  {%- else -%}
    {{ return({'database': target.database, 'schema': parts[0]}) }}
  {%- endif -%}
{% endmacro %}

{#-
  All columns across the configured datasets, as a subquery body yielding
  (table_catalog, table_schema, table_name, column_name). table_catalog is the
  GCP project (BigQuery) / database (Snowflake) the row actually lives in — not
  assumed to be target.project/target.database, so results stay correct when a
  dataset comes from another project. BigQuery scopes INFORMATION_SCHEMA per
  dataset, so it unions one select per dataset; Snowflake's is one
  database-wide information_schema, so datasets are grouped by database and
  filtered by schema — and lowercased, since Snowflake stores unquoted
  identifiers uppercase while the dbt graph (and BigQuery) use lowercase.
-#}
{% macro pii_information_schema_columns(datasets) %}
  {{ return(adapter.dispatch('pii_information_schema_columns', 'chameleon_pii')(datasets)) }}
{% endmacro %}

{% macro bigquery__pii_information_schema_columns(datasets) %}
  {%- for ds in datasets %}
  {%- set parsed = chameleon_pii.pii_split_dataset(ds) %}
  select table_catalog, table_schema, table_name, column_name
  from `{{ parsed.database }}.{{ parsed.schema }}.INFORMATION_SCHEMA.COLUMNS`
  {%- if not loop.last %}
  union all
  {%- endif %}
  {%- endfor %}
{% endmacro %}

{% macro snowflake__pii_information_schema_columns(datasets) %}
  {%- set by_database = {} %}
  {%- for ds in datasets %}
    {%- set parsed = chameleon_pii.pii_split_dataset(ds) %}
    {%- if parsed.database not in by_database %}{% do by_database.update({parsed.database: []}) %}{% endif %}
    {%- do by_database[parsed.database].append(parsed.schema | lower) %}
  {%- endfor %}
  {%- for database, schemas in by_database.items() %}
  select
    table_catalog,
    lower(table_schema) as table_schema,
    lower(table_name) as table_name,
    lower(column_name) as column_name
  from {{ database }}.information_schema.columns
  where lower(table_schema) in (
    {%- for s in schemas %}'{{ s }}'{% if not loop.last %}, {% endif %}{% endfor -%}
  )
  {%- if not loop.last %}
  union all
  {%- endif %}
  {%- endfor %}
{% endmacro %}

{% macro default__pii_information_schema_columns(datasets) %}
  {{ chameleon_pii.snowflake__pii_information_schema_columns(datasets) }}
{% endmacro %}
