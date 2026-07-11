{#
  Content/value scanning. Unlike the metadata planes, this reads actual column VALUES
  to catch PII that does not announce itself in the column name (e.g. an email inside a
  free-text `notes` column). It is the expensive plane, so it is OFF by default
  (`pii_content_scan_enabled`) and built with guardrails:

    - samples base tables with TABLESAMPLE (percent configurable);
    - scans only STRING columns whose NAME is innocent (declared / name-matching columns
      are already handled by the registry + discovery);
    - one sampled scan per table (all column x pattern counts in a single pass);
    - the model carries a maximum_bytes_billed cap.
#}

{% macro content_scan_value_patterns() %}
  {{ return(var('pii_value_patterns', {
    'EMAIL': '[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}',
    'PHONE': '(\\+\\d{1,3}[ .\\-]?)?\\(?\\d{3}\\)?[ .\\-]\\d{3}[ .\\-]\\d{4}',
    'SSN': '\\d{3}-\\d{2}-\\d{4}',
    'CREDIT_CARD': '\\d{4}[ \\-]?\\d{4}[ \\-]?\\d{4}[ \\-]?\\d{4}',
    'IP': '\\b\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b'
  })) }}
{% endmacro %}


{% macro content_scan_pattern_class(pattern) %}
  {% set map = {
    'EMAIL': 'DIRECT_IDENTIFIER',
    'PHONE': 'CONTACT',
    'SSN': 'DIRECT_IDENTIFIER',
    'CREDIT_CARD': 'SENSITIVE',
    'IP': 'QUASI_IDENTIFIER'
  } %}
  {{ return(map.get(pattern, 'SENSITIVE')) }}
{% endmacro %}


{#
  Returns the STRING columns worth scanning: base tables only, name-innocent
  (not declared, not matching a PII name pattern), excluding the package outputs.
#}
{% macro get_content_scan_candidates(datasets) %}
  {% set candidates = [] %}
  {% if not execute %}{{ return(candidates) }}{% endif %}

  {% set declared = chameleon_pii.get_pii_columns() %}
  {% set declared_keys = [] %}
  {% for d in declared %}{% do declared_keys.append(d.model_name ~ '.' ~ d.field_name) %}{% endfor %}

  {% set own_tables = ['pii_registry', 'pii_field_lineage', 'pii_discovery', 'pii_shred_readiness', 'pii_content_findings'] %}

  {% set query %}
    {% for ds in datasets %}
    select '{{ ds }}' as dataset, c.table_name, c.column_name
    from `{{ target.project }}.{{ ds }}.INFORMATION_SCHEMA.COLUMNS` c
    join `{{ target.project }}.{{ ds }}.INFORMATION_SCHEMA.TABLES` t
      on c.table_name = t.table_name
    where t.table_type = 'BASE TABLE' and c.data_type = 'STRING'
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
  {% endset %}

  {% set results = run_query(query) %}
  {% for row in results %}
    {% set tbl = row['table_name'] %}
    {% set col = row['column_name'] %}
    {% if tbl in own_tables %}{% continue %}{% endif %}
    {% if (tbl ~ '.' ~ col) in declared_keys %}{% continue %}{% endif %}
    {% if chameleon_pii.infer_pii_from_name(col) is not none %}{% continue %}{% endif %}
    {% do candidates.append({'dataset': row['dataset'], 'table': tbl, 'column': col}) %}
  {% endfor %}

  {{ return(candidates) }}
{% endmacro %}


{% macro build_content_findings_sql() %}
  {%- set empty_sql -%}
    select *
    from (
      select
        cast(null as {{ dbt.type_string() }}) as system,
        cast(null as {{ dbt.type_string() }}) as table_name,
        cast(null as {{ dbt.type_string() }}) as column_name,
        cast(null as {{ dbt.type_string() }}) as pattern,
        cast(null as {{ dbt.type_string() }}) as classification,
        cast(null as {{ dbt.type_int() }}) as sampled_rows,
        cast(null as {{ dbt.type_int() }}) as match_count,
        cast(null as {{ dbt.type_float() }}) as match_rate,
        cast(null as {{ dbt.type_timestamp() }}) as scanned_at
    ) as _shell
    where false
  {%- endset -%}

  {% if not var('pii_content_scan_enabled', false) or not execute %}
    {{ return(empty_sql) }}
  {% endif %}

  {# Content scanning uses BigQuery-specific SQL (TABLESAMPLE, bytes-billed cap).
     On other adapters the model builds as an empty shell. #}
  {% if target.type != 'bigquery' %}
    {% do log('chameleon_pii: content scanning is BigQuery-only for now; pii_content_findings will be empty on ' ~ target.type ~ '.', info=True) %}
    {{ return(empty_sql) }}
  {% endif %}

  {% set datasets = var('pii_content_scan_datasets', [target.schema]) %}
  {% set pct = var('pii_content_sample_percent', 10) %}
  {% set patterns = chameleon_pii.content_scan_value_patterns() %}
  {% set candidates = chameleon_pii.get_content_scan_candidates(datasets) %}

  {% if candidates | length == 0 %}
    {{ return(empty_sql) }}
  {% endif %}

  {% set tables = {} %}
  {% for c in candidates %}
    {% set key = c.dataset ~ '.' ~ c.table %}
    {% if key not in tables %}{% do tables.update({key: {'dataset': c.dataset, 'table': c.table, 'columns': []}}) %}{% endif %}
    {% do tables[key].columns.append(c.column) %}
  {% endfor %}

  {% set agg_ctes = [] %}
  {% set union_selects = [] %}
  {% set ns = namespace(alias_id=0) %}

  {% for key, tbl in tables.items() %}
    {% set safe = 't_' ~ (key | replace('.', '__') | replace('-', '_')) %}
    {% set countif_exprs = [] %}
    {% set col_pat = [] %}
    {% for col in tbl.columns %}
      {% for pat_name, regex in patterns.items() %}
        {% set ns.alias_id = ns.alias_id + 1 %}
        {% set alias = 'mc_' ~ ns.alias_id %}
        {% do countif_exprs.append("countif(regexp_contains(`" ~ col ~ "`, r'" ~ regex ~ "')) as " ~ alias) %}
        {% do col_pat.append({'col': col, 'pattern': pat_name, 'alias': alias}) %}
      {% endfor %}
    {% endfor %}
    {% set sample_clause = '' if pct >= 100 else ' tablesample system (' ~ pct ~ ' percent)' %}
    {% set cte %}
{{ safe }}_agg as (
  select count(*) as sampled_rows, {{ countif_exprs | join(', ') }}
  from `{{ target.project }}.{{ tbl.dataset }}.{{ tbl.table }}`{{ sample_clause }}
)
    {%- endset %}
    {% do agg_ctes.append(cte) %}
    {% for cp in col_pat %}
      {% set sel %}
select '{{ tbl.table }}' as table_name, '{{ cp.col }}' as column_name, '{{ cp.pattern }}' as pattern,
       '{{ chameleon_pii.content_scan_pattern_class(cp.pattern) }}' as classification,
       sampled_rows, {{ cp.alias }} as match_count
from {{ safe }}_agg
      {%- endset %}
      {% do union_selects.append(sel) %}
    {% endfor %}
  {% endfor %}

  {% set final %}
with
{{ agg_ctes | join(',\n') }},
findings as (
{{ union_selects | join('\nunion all\n') }}
)
select
  '{{ target.type }}' as system,
  table_name, column_name, pattern, classification,
  sampled_rows, match_count,
  safe_divide(match_count, sampled_rows) as match_rate,
  current_timestamp() as scanned_at
from findings
where match_count > 0
  {% endset %}
  {{ return(final) }}
{% endmacro %}
