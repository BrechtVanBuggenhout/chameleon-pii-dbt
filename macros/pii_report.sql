{#-
  Human-readable summary of everything the package found, printed to the terminal.

    dbt run-operation pii_report

  Reads the five pii_* tables (whichever exist) and prints registry counts,
  lineage depth, undeclared findings with allowlist status, and the shred-
  readiness verdicts. Read-only: a handful of tiny aggregate queries.
-#}

{% macro pii_report() %}
  {%- if not execute -%}{{ return('') }}{%- endif -%}

  {%- set registry_rel = load_relation(ref('pii_registry')) -%}
  {%- if registry_rel is none -%}
    {{ log("chameleon_pii: pii_registry not found in the warehouse.", info=True) }}
    {{ log("Run `dbt build --select package:chameleon_pii` first, then re-run this report.", info=True) }}
    {{ return('') }}
  {%- endif -%}

  {%- set allowlist = var('pii_undeclared_allowlist', []) -%}
  {%- set hr = '─' * 62 -%}

  {#-
    Aliases go through adapter.quote() so the result set keeps this exact
    (lowercase) casing regardless of adapter quoting syntax (backticks on
    BigQuery, double quotes on Snowflake/ANSI). Snowflake uppercases
    unquoted identifiers (including SELECT aliases), which would otherwise
    make every row[...] lookup below silently miss.
  -#}
  {%- set q_total = adapter.quote('total') -%}
  {%- set q_models = adapter.quote('models') -%}
  {%- set q_declared = adapter.quote('declared') -%}
  {%- set q_inferred = adapter.quote('inferred') -%}
  {%- set q_discovered = adapter.quote('discovered') -%}
  {%- set q_flows = adapter.quote('flows') -%}
  {%- set q_max_hops = adapter.quote('max_hops') -%}
  {%- set q_ready = adapter.quote('ready') -%}
  {%- set q_at_risk = adapter.quote('at_risk') -%}
  {%- set q_not_shreddable = adapter.quote('not_shreddable') -%}
  {%- set q_unregistered = adapter.quote('unregistered') -%}
  {%- set q_table_name = adapter.quote('table_name') -%}
  {%- set q_field_name = adapter.quote('field_name') -%}
  {%- set q_classification = adapter.quote('classification') -%}
  {%- set q_reaches_mart = adapter.quote('reaches_mart') -%}
  {%- set q_n = adapter.quote('n') -%}

  {%- set registry_row = run_query(
    "select count(*) as " ~ q_total ~ ", count(distinct model_name) as " ~ q_models ~ ","
    ~ " sum(case when detection_method = 'DECLARED' then 1 else 0 end) as " ~ q_declared ~ ","
    ~ " sum(case when detection_method = 'NAME_INFERENCE' then 1 else 0 end) as " ~ q_inferred ~ ","
    ~ " sum(case when detection_method = 'INFORMATION_SCHEMA' then 1 else 0 end) as " ~ q_discovered
    ~ " from " ~ ref('pii_registry')
  ).rows[0] -%}

  {%- set lineage_row = run_query(
    "select count(*) as " ~ q_flows ~ ", coalesce(max(hops), 0) as " ~ q_max_hops ~ " from " ~ ref('pii_field_lineage')
  ).rows[0] -%}

  {%- set readiness_row = run_query(
    "select"
    ~ " sum(case when readiness = 'READY' then 1 else 0 end) as " ~ q_ready ~ ","
    ~ " sum(case when readiness = 'AT_RISK' then 1 else 0 end) as " ~ q_at_risk ~ ","
    ~ " sum(case when readiness = 'NOT_SHREDDABLE' then 1 else 0 end) as " ~ q_not_shreddable ~ ","
    ~ " sum(case when readiness = 'UNREGISTERED' then 1 else 0 end) as " ~ q_unregistered
    ~ " from " ~ ref('pii_shred_readiness')
  ).rows[0] -%}

  {%- set findings = run_query(
    "select table_name as " ~ q_table_name ~ ", field_name as " ~ q_field_name ~ ","
    ~ " classification as " ~ q_classification ~ ", reaches_mart as " ~ q_reaches_mart
    ~ " from " ~ ref('pii_shred_readiness')
    ~ " where readiness = 'UNREGISTERED'"
    ~ " order by reaches_mart desc, table_name, field_name limit 15"
  ).rows -%}

  {%- set content_rel = load_relation(ref('pii_content_findings')) -%}
  {%- set content_count = none -%}
  {%- if content_rel is not none and var('pii_content_scan_enabled', false) -%}
    {%- set content_count = run_query("select count(*) as " ~ q_n ~ " from " ~ ref('pii_content_findings')).rows[0]['n'] -%}
  {%- endif -%}

  {{ log('', info=True) }}
  {{ log(hr, info=True) }}
  {{ log(' chameleon_pii report — ' ~ target.type ~ ':' ~ target.database ~ '.' ~ target.schema, info=True) }}
  {{ log(hr, info=True) }}
  {{ log(' Registry     ' ~ registry_row['total'] ~ ' PII field(s) across ' ~ registry_row['models'] ~ ' table(s)', info=True) }}
  {{ log('              ' ~ registry_row['declared'] ~ ' declared · ' ~ registry_row['inferred'] ~ ' name-inferred · ' ~ registry_row['discovered'] ~ ' auto-registered from discovery', info=True) }}
  {{ log(' Lineage      ' ~ lineage_row['flows'] ~ ' downstream flow(s), deepest path ' ~ lineage_row['max_hops'] ~ ' hop(s)', info=True) }}
  {{ log(' Readiness    READY ' ~ readiness_row['ready'] ~ ' · AT_RISK ' ~ readiness_row['at_risk'] ~ ' · NOT_SHREDDABLE ' ~ readiness_row['not_shreddable'] ~ ' · UNREGISTERED ' ~ readiness_row['unregistered'], info=True) }}

  {%- if findings | length > 0 %}
  {{ log('', info=True) }}
  {{ log(' Undeclared PII:', info=True) }}
    {%- for f in findings %}
      {%- set key = f['table_name'] ~ '.' ~ f['field_name'] %}
      {%- set marker = '!' if f['reaches_mart'] else '•' %}
      {%- set notes = [] %}
      {%- if f['reaches_mart'] %}{% do notes.append('reaches mart') %}{% endif %}
      {%- if key in allowlist %}{% do notes.append('allowlisted') %}{% endif %}
      {%- set suffix = ' — ' ~ notes | join(', ') if notes | length > 0 else '' %}
  {{ log('   ' ~ marker ~ ' ' ~ key ~ ' (' ~ f['classification'] ~ ')' ~ suffix, info=True) }}
    {%- endfor %}
  {%- endif %}

  {%- if content_count is not none %}
  {{ log(' Content scan ' ~ content_count ~ ' value-level finding(s)', info=True) }}
  {%- else %}
  {{ log(' Content scan off (set pii_content_scan_enabled: true to sample values)', info=True) }}
  {%- endif %}

  {{ log(hr, info=True) }}
  {%- set unallowlisted = [] -%}
  {%- for f in findings -%}
    {%- set key = f['table_name'] ~ '.' ~ f['field_name'] -%}
    {%- if key not in allowlist %}{% do unallowlisted.append(key) %}{% endif -%}
  {%- endfor -%}
  {%- if unallowlisted | length > 0 %}
  {{ log(' Next: declare real findings with meta.pii in schema.yml; add reviewed', info=True) }}
  {{ log(' false positives to pii_undeclared_allowlist; set', info=True) }}
  {{ log(' pii_undeclared_severity: error in CI to block new leaks.', info=True) }}
  {%- else %}
  {{ log(' All findings declared or allowlisted. Set pii_undeclared_severity: error', info=True) }}
  {{ log(' in CI to keep it that way.', info=True) }}
  {%- endif %}
  {{ log(hr, info=True) }}
  {{ log('', info=True) }}
{% endmacro %}
