{# Default handling strategy for a classification when the user did not declare one. #}
{% macro default_handling(classification) %}
  {% set map = {
    "DIRECT_IDENTIFIER": "ENCRYPT",
    "QUASI_IDENTIFIER": "REDACT",
    "CONTACT": "ENCRYPT",
    "SENSITIVE": "ENCRYPT",
    "BEHAVIORAL": "ALLOW_AGGREGATE_ONLY",
    "SYSTEM_IDENTIFIER": "HASH_SURROGATE"
  } %}
  {{ return(map.get(classification, "MANUAL_REVIEW")) }}
{% endmacro %}


{# Infer the layer of a model from its path / fqn. Override per-model with
   meta.chameleon.layer. Returns RAW | STAGING | INTERMEDIATE | MART | UNKNOWN. #}
{% macro infer_layer(node) %}
  {% set declared = node.meta.get("chameleon", {}).get("layer") %}
  {% if declared %}{{ return(declared) }}{% endif %}
  {% set path = (node.path | default("")) | lower %}
  {% set name = (node.name | default("")) | lower %}
  {% if "staging" in path or name.startswith("stg_") %}{{ return("STAGING") }}
  {% elif "intermediate" in path or name.startswith("int_") %}{{ return("INTERMEDIATE") }}
  {% elif "mart" in path or name.startswith("mart_") or name.startswith("dim_") or name.startswith("fct_") %}{{ return("MART") }}
  {% elif "raw" in path or name.startswith("raw_") %}{{ return("RAW") }}
  {% else %}{{ return("UNKNOWN") }}{% endif %}
{% endmacro %}


{# Match a column name against the configured patterns. Returns a classification
   string or none. Patterns come from var('pii_name_patterns'). #}
{% macro infer_pii_from_name(column_name) %}
  {% if not var("pii_inference_enabled", true) %}{{ return(none) }}{% endif %}
  {% set patterns = var("pii_name_patterns", {}) %}
  {% set col = column_name | lower %}
  {% for pattern, classification in patterns.items() %}
    {% if modules.re.search(pattern, col) %}
      {{ return(classification) }}
    {% endif %}
  {% endfor %}
  {{ return(none) }}
{% endmacro %}
