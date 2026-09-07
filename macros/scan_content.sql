{#
  Content/value scanning. Unlike the metadata planes, this reads actual column VALUES
  to catch PII that does not announce itself in the column name (e.g. an email inside a
  free-text `notes` column). It is the expensive plane, so it is OFF by default
  (`pii_content_scan_enabled`) and built with guardrails:

    - samples base tables with TABLESAMPLE (percent configurable);
    - scans STRING and JSON columns whose NAME is innocent (declared / name-matching
      columns are already handled by the registry + discovery); JSON columns are
      scanned whole-blob (TO_JSON_STRING), so a finding means "somewhere in this
      column", not a specific nested key -- STRUCT/RECORD columns are not scanned
      (see get_content_scan_candidates for why);
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
  Returns the STRING and JSON columns worth scanning: base tables only,
  name-innocent (not declared, not matching a PII name pattern), excluding
  the package outputs. `datasets` entries may be a plain schema name
  (implicitly target.project) or a fully-qualified "project.schema"
  (chameleon_pii.pii_split_dataset), so scanning can span GCP projects, not
  just the target one.

  JSON columns are scanned whole-blob (see build_content_findings_sql's
  TO_JSON_STRING wrapping) -- this finds that a JSON column contains PII
  *somewhere*, not which nested key. STRUCT/RECORD columns are deliberately
  NOT included here: unlike JSON, a STRUCT's sub-fields can already be
  individually declared in the registry at "table.column" granularity (see
  e.g. raw_users.pii_fields), so scanning the whole STRUCT would produce
  noisy duplicate findings against fields the registry already governs,
  with no way to exclude just the declared sub-field.
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
    {%- set parsed = chameleon_pii.pii_split_dataset(ds) %}
    select '{{ parsed.database }}' as project, '{{ parsed.schema }}' as dataset, c.table_name, c.column_name, c.data_type
    from `{{ parsed.database }}.{{ parsed.schema }}.INFORMATION_SCHEMA.COLUMNS` c
    join `{{ parsed.database }}.{{ parsed.schema }}.INFORMATION_SCHEMA.TABLES` t
      on c.table_name = t.table_name
    where t.table_type = 'BASE TABLE' and c.data_type in ('STRING', 'JSON')
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
    {% do candidates.append({'project': row['project'], 'dataset': row['dataset'], 'table': tbl, 'column': col, 'data_type': row['data_type']}) %}
  {% endfor %}

  {{ return(candidates) }}
{% endmacro %}


{#
  Stage 2: path-level JSON PII findings. Where the whole-blob TO_JSON_STRING scan
  below can only say "this JSON column has PII somewhere", this discovers the actual
  paths present in real sampled data so build_content_findings_sql can generate
  precise per-path countifs.

  Discovery runs via a temp JS UDF, not native BigQuery JSON functions, for a real
  reason found while building this: BigQuery requires the JSONPath argument to
  JSON_QUERY/JSON_VALUE to be a compile-time constant -- confirmed live, a query
  trying to classify a path discovered via UNNEST(JSON_KEYS(...)) by feeding that
  per-row path string back into JSON_QUERY fails with "Argument 2 to JSON_QUERY must
  be a constant expression". A JS UDF sidesteps this by walking the already-parsed
  JSON entirely in JavaScript, never calling a BigQuery JSON function with a
  computed path. (The final scan SQL this feeds into doesn't have this problem --
  Jinja bakes each discovered path into the generated SQL as a literal string,
  which *is* a constant expression to BigQuery.)

  The UDF returns every path with its JS `typeof`-based kind, plus an `[]` marker
  segment showing where array boundaries are (confirmed live: `{"contacts":
  [{"email":"a"}]}` -> "contacts" (array), "contacts[]" (object),
  "contacts[].email" (string) -- an array of plain scalars like `{"tags":["a"]}`
  reports "tags[]" as kind "string" directly, no further nesting). Only one level
  of array recursion is used (per the agreed scope) -- a path containing more than
  one "[]" is a nested array-in-array-element and is skipped.

  `json_candidates` is the JSON-typed subset of get_content_scan_candidates()'s
  output. Returns a flat list of
    {project, dataset, table, column, kind: 'scalar'|'array', path, element_path}
  where `path` is JSONPath ('$.contact.email'), and for kind='array', `element_path`
  is the JSONPath *within* one array element ('$.email'), or '$' if the array holds
  plain scalars rather than objects.
#}
{#
  BigQuery's JSON_VALUE/JSON_QUERY only accept a bare-identifier key in dot
  notation -- confirmed live against real BigQuery that quoted bracket access
  ($['key']) isn't supported at all (numeric brackets like $[0] work fine;
  quoted-string brackets error with "Invalid token in JSONPath" regardless of
  quote style or escaping). A key with a space, apostrophe, or other
  non-identifier character genuinely can't be looked up this way in BigQuery --
  not an escaping problem, a JSONPath-dialect limitation. Used to decide
  whether a discovered path is safe to build a targeted countif for at all.
#}
{% macro _is_safe_dotted_json_path(path) %}
  {% set ns_seg = namespace(safe=true) %}
  {% for seg in path.split('.') %}
    {% if seg | length == 0 or not (seg.isascii() and seg.isidentifier()) %}{% set ns_seg.safe = false %}{% endif %}
  {% endfor %}
  {{ return(ns_seg.safe) }}
{% endmacro %}


{% macro get_json_path_candidates(json_candidates, pct) %}
  {% set path_candidates = [] %}
  {% if not execute or json_candidates | length == 0 %}{{ return(path_candidates) }}{% endif %}

  {%- set udf -%}
    create temp function chameleon_pii_discover_json_paths(json_str string)
    returns array<struct<path string, kind string>>
    language js as r"""
    function walk(obj, prefix, results) {
      if (obj === null || obj === undefined) return;
      if (Array.isArray(obj)) {
        results.push({path: prefix, kind: 'array'});
        for (var i = 0; i < obj.length; i++) {
          walk(obj[i], prefix + '[]', results);
        }
      } else if (typeof obj === 'object') {
        if (prefix !== '') results.push({path: prefix, kind: 'object'});
        for (var key in obj) {
          walk(obj[key], prefix ? prefix + '.' + key : key, results);
        }
      } else {
        results.push({path: prefix, kind: typeof obj});
      }
    }
    var results = [];
    try {
      var parsed = JSON.parse(json_str);
      walk(parsed, '', results);
    } catch (e) {}
    return results;
    """;
  {%- endset -%}

  {% set tables = {} %}
  {% for c in json_candidates %}
    {% set key = c.project ~ '.' ~ c.dataset ~ '.' ~ c.table %}
    {% if key not in tables %}{% do tables.update({key: {'project': c.project, 'dataset': c.dataset, 'table': c.table, 'columns': []}}) %}{% endif %}
    {% do tables[key].columns.append(c.column) %}
  {% endfor %}

  {% set sample_clause = '' if pct >= 100 else ' tablesample system (' ~ pct ~ ' percent)' %}

  {% for key, tbl in tables.items() %}
    {#- One TABLESAMPLE read of this table -- the base table is only ever
       referenced as `t` inside the struct literal below, so this stays within
       the "sampled table referenced once" rule the final scan also needs. #}
    {% set col_structs = [] %}
    {% for col in tbl.columns %}
      {% do col_structs.append("struct('" ~ col ~ "' as column_name, to_json_string(t.`" ~ col ~ "`) as val)") %}
    {% endfor %}
    {% set discover_query %}
      {{ udf }}
      select c.column_name, d.path, d.kind
      from `{{ tbl.project }}.{{ tbl.dataset }}.{{ tbl.table }}` as t{{ sample_clause }},
      unnest([{{ col_structs | join(',\n') }}]) as c,
      unnest(chameleon_pii_discover_json_paths(c.val)) as d
      group by c.column_name, d.path, d.kind
    {% endset %}
    {% set discover_results = run_query(discover_query) %}

    {#- Lookup for "what kind is this exact (column, path)" -- used below to check
       an array's element kind (path ~ '[]') without a second linear scan. #}
    {% set kind_by_key = {} %}
    {% for row in discover_results %}
      {% do kind_by_key.update({row['column_name'] ~ '|' ~ row['path']: row['kind']}) %}
    {% endfor %}

    {% for row in discover_results %}
      {% set path = row['path'] %}
      {% set col = row['column_name'] %}
      {% set kind = row['kind'] %}
      {% if kind == 'object' or '[]' in path %}
        {#- container marker, or something found *inside* an array -- object
           markers carry no value of their own, and paths inside an array are
           only ever consumed below via the owning array's own row, never
           iterated standalone (skips anything more than one array level deep
           too, since a 2nd-level path already contains '[]' itself). #}
        {% continue %}
      {% endif %}
      {% if not chameleon_pii._is_safe_dotted_json_path(path) %}
        {#- a real key with a special character (space, apostrophe, ...) --
           can't be looked up via JSON_VALUE's dot-notation path at all, see
           _is_safe_dotted_json_path above. Skip path-level detection for it;
           the whole-blob TO_JSON_STRING scan above still covers it, coarsely. #}
        {% continue %}
      {% endif %}
      {% if kind in ('string', 'number', 'boolean') %}
        {% do path_candidates.append({'project': tbl.project, 'dataset': tbl.dataset, 'table': tbl.table, 'column': col, 'kind': 'scalar', 'path': '$.' ~ path, 'element_path': none}) %}
      {% elif kind == 'array' %}
        {% set elem_kind = kind_by_key.get(col ~ '|' ~ path ~ '[]') %}
        {% if elem_kind in ('string', 'number', 'boolean') %}
          {#- array of plain scalars -- match against the element itself #}
          {% do path_candidates.append({'project': tbl.project, 'dataset': tbl.dataset, 'table': tbl.table, 'column': col, 'kind': 'array', 'path': '$.' ~ path, 'element_path': '$'}) %}
        {% elif elem_kind == 'object' %}
          {#- array of objects -- one candidate per scalar leaf found inside an
             element, at any depth within that one element (still one array
             level, since the leaf path itself contains no further '[]'). #}
          {% set leaf_prefix = path ~ '[].' %}
          {% for leaf in discover_results %}
            {% set leaf_suffix = leaf['path'][(leaf_prefix | length):] %}
            {% if leaf['column_name'] == col and leaf['kind'] in ('string', 'number', 'boolean') and leaf['path'].startswith(leaf_prefix) and chameleon_pii._is_safe_dotted_json_path(leaf_suffix) %}
              {% do path_candidates.append({'project': tbl.project, 'dataset': tbl.dataset, 'table': tbl.table, 'column': col, 'kind': 'array', 'path': '$.' ~ path, 'element_path': '$.' ~ leaf_suffix}) %}
            {% endif %}
          {% endfor %}
        {% endif %}
        {#- elem_kind == 'array' (array of arrays), or none (always empty in the
           sample) -- out of scope / nothing to discover, skipped either way. #}
      {% endif %}
    {% endfor %}
  {% endfor %}

  {{ return(path_candidates) }}
{% endmacro %}


{% macro build_content_findings_sql() %}
  {%- set empty_sql -%}
    select *
    from (
      select
        cast(null as {{ dbt.type_string() }}) as system,
        cast(null as {{ dbt.type_string() }}) as table_catalog,
        cast(null as {{ dbt.type_string() }}) as table_schema,
        cast(null as {{ dbt.type_string() }}) as table_name,
        cast(null as {{ dbt.type_string() }}) as column_name,
        cast(null as {{ dbt.type_string() }}) as source_data_type,
        cast(null as {{ dbt.type_string() }}) as json_path,
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

  {% set datasets = var('pii_content_scan_datasets', chameleon_pii.pii_discovered_datasets()) %}
  {% set pct = var('pii_content_sample_percent', 10) %}
  {% set patterns = chameleon_pii.content_scan_value_patterns() %}
  {% set candidates = chameleon_pii.get_content_scan_candidates(datasets) %}

  {% if candidates | length == 0 %}
    {{ return(empty_sql) }}
  {% endif %}

  {% set tables = {} %}
  {% for c in candidates %}
    {% set key = c.project ~ '.' ~ c.dataset ~ '.' ~ c.table %}
    {% if key not in tables %}{% do tables.update({key: {'project': c.project, 'dataset': c.dataset, 'table': c.table, 'columns': []}}) %}{% endif %}
    {% do tables[key].columns.append({'name': c.column, 'data_type': c.data_type}) %}
  {% endfor %}

  {#- Stage 2: path-level findings for JSON columns, additive to the whole-blob scan
     below. See get_json_path_candidates for why this needs its own discovery pass. #}
  {% set json_path_candidates = chameleon_pii.get_json_path_candidates(candidates | selectattr('data_type', 'equalto', 'JSON') | list, pct) %}
  {% set paths_by_table = {} %}
  {% for p in json_path_candidates %}
    {% set pkey = p.project ~ '.' ~ p.dataset ~ '.' ~ p.table %}
    {% if pkey not in paths_by_table %}{% do paths_by_table.update({pkey: []}) %}{% endif %}
    {% do paths_by_table[pkey].append(p) %}
  {% endfor %}

  {% set agg_ctes = [] %}
  {% set union_selects = [] %}
  {% set ns = namespace(alias_id=0) %}

  {% for key, tbl in tables.items() %}
    {% set safe = 't_' ~ (key | replace('.', '__') | replace('-', '_')) %}
    {% set countif_exprs = [] %}
    {% set col_pat = [] %}
    {% for col in tbl.columns %}
      {#- JSON columns are flattened with TO_JSON_STRING before pattern
         matching, so whole-value regex matching finds PII anywhere inside
         the blob; STRING columns keep the exact expression this macro has
         always generated, so existing scans are byte-identical. #}
      {% set col_expr = ('`' ~ col.name ~ '`') if col.data_type == 'STRING' else ('TO_JSON_STRING(`' ~ col.name ~ '`)') %}
      {% for pat_name, regex in patterns.items() %}
        {% set ns.alias_id = ns.alias_id + 1 %}
        {% set alias = 'mc_' ~ ns.alias_id %}
        {% do countif_exprs.append("countif(regexp_contains(" ~ col_expr ~ ", r'" ~ regex ~ "')) as " ~ alias) %}
        {% do col_pat.append({'col': col.name, 'data_type': col.data_type, 'pattern': pat_name, 'alias': alias, 'json_path': none}) %}
      {% endfor %}
    {% endfor %}

    {#- Stage 2 path-level countifs, appended into the SAME agg CTE as the columns
       above -- no second TABLESAMPLE read. Scalar paths extract directly; array
       paths use EXISTS (did this row's array contain >=1 match), not a per-element
       SUM, so match_count stays one-per-row like every other finding here -- keeps
       the existing match_count <= sampled_rows invariant true with no exceptions,
       and avoids a correlated-subquery-SUM shape that wasn't confirmed safe. #}
    {#- jp.path / jp.element_path come from real JSON object keys discovered in
       sampled row DATA (get_json_path_candidates' JS UDF walks actual customer
       payloads, not just schema) -- not compile-time-known identifiers like a
       column name. Spliced unescaped into a SQL string literal, a single quote
       in a customer's own JSON key would break out of it. Escaped the same way
       test_no_undeclared_pii.sql already escapes untrusted values before
       interpolating into generated SQL. #}
    {% for jp in paths_by_table.get(key, []) %}
      {% set path_safe = jp.path | replace("'", "\\'") %}
      {% set element_path_safe = (jp.element_path | replace("'", "\\'")) if jp.element_path else jp.element_path %}
      {% for pat_name, regex in patterns.items() %}
        {% set ns.alias_id = ns.alias_id + 1 %}
        {% set alias = 'mc_' ~ ns.alias_id %}
        {% if jp.kind == 'scalar' %}
          {% do countif_exprs.append("countif(regexp_contains(json_value(`" ~ jp.column ~ "`, '" ~ path_safe ~ "'), r'" ~ regex ~ "')) as " ~ alias) %}
          {% set display_path = jp.path %}
        {% else %}
          {% do countif_exprs.append("countif(exists(select 1 from unnest(json_query_array(`" ~ jp.column ~ "`, '" ~ path_safe ~ "')) as elem where regexp_contains(json_value(elem, '" ~ element_path_safe ~ "'), r'" ~ regex ~ "'))) as " ~ alias) %}
          {% set elem_suffix = '' if jp.element_path == '$' else ('.' ~ (jp.element_path | replace('$.', ''))) %}
          {% set display_path = jp.path ~ '[*]' ~ elem_suffix %}
        {% endif %}
        {% do col_pat.append({'col': jp.column, 'data_type': 'JSON', 'pattern': pat_name, 'alias': alias, 'json_path': display_path}) %}
      {% endfor %}
    {% endfor %}
    {% set sample_clause = '' if pct >= 100 else ' tablesample system (' ~ pct ~ ' percent)' %}
    {% set cte %}
{{ safe }}_agg as (
  select count(*) as sampled_rows, {{ countif_exprs | join(', ') }}
  from `{{ tbl.project }}.{{ tbl.dataset }}.{{ tbl.table }}`{{ sample_clause }}
)
    {%- endset %}
    {% do agg_ctes.append(cte) %}
    {#- BigQuery rejects a TABLESAMPLE'd table (or a CTE derived from one)
       referenced more than once in a query ("Sampling of table ... not
       supported. Possible reasons: (1) sampled table referenced more than
       once..."). One SELECT per column x pattern, each with its own
       `FROM {safe}_agg`, hit that the moment a table had more than one
       candidate column and sample_percent < 100 -- invisible until now
       because the only place this has ever run (this package's own CI)
       always samples at exactly 100%, which skips TABLESAMPLE entirely
       (see sample_clause above). Fixed by referencing the aggregate CTE
       exactly once per table, via a single correlated UNNEST of a literal
       array of structs instead of one SELECT per row. #}
    {% set struct_exprs = [] %}
    {% for cp in col_pat %}
      {#- cp.json_path (for a JSON path-level entry) is display_path, itself
         built from the same unescaped-at-source jp.path/jp.element_path
         real-JSON-key values -- escape again here, at its own interpolation
         site, same as path_safe/element_path_safe above. #}
      {% set json_path_sql = "'" ~ (cp.json_path | replace("'", "\\'")) ~ "'" if cp.json_path else ('cast(null as ' ~ dbt.type_string() ~ ')') %}
      {% do struct_exprs.append("struct('" ~ cp.col ~ "' as column_name, '" ~ cp.data_type ~ "' as source_data_type, " ~ json_path_sql ~ " as json_path, '" ~ cp.pattern ~ "' as pattern, '" ~ chameleon_pii.content_scan_pattern_class(cp.pattern) ~ "' as classification, t." ~ cp.alias ~ " as match_count)") %}
    {% endfor %}
    {% set sel %}
select '{{ tbl.project }}' as table_catalog, '{{ tbl.dataset }}' as table_schema,
       '{{ tbl.table }}' as table_name,
       f.column_name, f.source_data_type, f.json_path, f.pattern, f.classification,
       t.sampled_rows, f.match_count
from {{ safe }}_agg as t,
unnest([
{{ struct_exprs | join(',\n') }}
]) as f
    {%- endset %}
    {% do union_selects.append(sel) %}
  {% endfor %}

  {% set final %}
with
{{ agg_ctes | join(',\n') }},
findings as (
{{ union_selects | join('\nunion all\n') }}
)
select
  '{{ target.type }}' as system,
  table_catalog, table_schema, table_name, column_name, source_data_type, json_path, pattern, classification,
  sampled_rows, match_count,
  safe_divide(match_count, sampled_rows) as match_rate,
  current_timestamp() as scanned_at
from findings
where match_count > 0
  {% endset %}
  {{ return(final) }}
{% endmacro %}
