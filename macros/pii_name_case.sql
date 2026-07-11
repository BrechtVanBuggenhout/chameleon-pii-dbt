{#
  Renders the configured `pii_name_patterns` as a SQL CASE expression so column-name
  inference can run inside the warehouse (pushdown) instead of in Jinja. First match
  wins, mirroring the row-by-row `infer_pii_from_name` macro. Returns NULL when nothing
  matches. Regex execution goes through the cross-adapter pii_regexp macro.
#}
{% macro pii_name_case(column_expr) %}
  {%- set patterns = var("pii_name_patterns", {}) -%}
  case
  {%- for pattern, classification in patterns.items() %}
    when {{ chameleon_pii.pii_regexp('lower(' ~ column_expr ~ ')', pattern) }} then '{{ classification }}'
  {%- endfor %}
    else null
  end
{%- endmacro %}
