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


{# Default pii_name_exclude_patterns -- lives here, not just in this package's
   own dbt_project.yml, because a dbt package can never push vars into a
   consuming project: var('pii_name_exclude_patterns', X) only ever falls
   back to X when the CONSUMING project hasn't set the var itself, and a
   fresh install never has. Without a real default here, "zero config, finds
   your PII automatically" was false for any project with metric/dimension
   columns shaped like metrics_phone_impressions or ad_group_name -- the
   patterns existed (in this repo's own dbt_project.yml) but never actually
   applied anywhere except this package's own test project. #}
{% macro default_pii_name_exclude_patterns() %}
  {{ return([
    "^metrics?_",
    "_(impressions|clicks|views|sessions|conversions|count|counts|total|totals|sum|avg|average|pct|percentage|rate|ratio|score|spend|cost|revenue|ctr|cpc|cpm|roas)$",
    "(^|_)(event|campaign|ad_group|ad_set|segment|cohort|experiment|variant|product|category|page|screen|report|dashboard|workflow|model|table|column|field|dataset|schema|project|metric|dimension|tag|label|template|theme|plan|tier|sku|brand|store|app|device|browser|os)_name(_|$)"
  ]) }}
{% endmacro %}


{# Default pii_name_patterns -- same bug class as default_pii_name_exclude_patterns()
   above, just never given the same fix: var('pii_name_patterns', X) only ever
   falls back to X when the CONSUMING project hasn't set the var, and a fresh
   install never has. This package's own dbt_project.yml declared a real pattern
   list, but that's only visible within this repo's own dev/integration-test
   runs -- confirmed live (2026-09-12): on dbt-core 1.12.x specifically, a
   dependency package's own dbt_project.yml vars are NOT used as a fallback
   default for that package's own macros in a consuming project (dbt-core
   1.10.x's behavior differs and happened to mask this for this project's own
   real usage, which pins 1.10.22 -- a genuinely fresh external install on
   current dbt-core got zero detections, silently, no error). Without a real
   default here, "zero config, finds your PII automatically" was false for
   every real external installer. #}
{% macro default_pii_name_patterns() %}
  {{ return({
    "(^|_)email(_|$)": "DIRECT_IDENTIFIER",
    "(^|_)e_?mail": "DIRECT_IDENTIFIER",
    "(^|_)phone(_|$)|msisdn|mobile_number": "CONTACT",
    "(^|_)ssn(_|$)|social_security": "DIRECT_IDENTIFIER",
    "(^|_)dob(_|$)|date_of_birth|birth_date": "QUASI_IDENTIFIER",
    "first_name|last_name|full_name|(^|_)name$": "DIRECT_IDENTIFIER",
    "(^|_)address(_|$)|street|postcode|zip_code|postal": "QUASI_IDENTIFIER",
    "(^|_)ip(_address)?$|ip_addr": "QUASI_IDENTIFIER",
    "passport|national_id|tax_id|drivers_license": "DIRECT_IDENTIFIER",
    "credit_card|card_number|iban|account_number": "SENSITIVE"
  }) }}
{% endmacro %}


{# Match a column name against the configured patterns. Returns a classification
   string or none. Patterns come from var('pii_name_patterns')
   (default_pii_name_patterns() above, unless the consuming project overrides
   it). Columns matching var('pii_name_exclude_patterns')
   (default_pii_name_exclude_patterns() above, unless the consuming project
   overrides it) are vetoed first, e.g. so a metric field like
   `metrics_phone_impressions` doesn't get flagged just because it contains
   "phone". #}
{% macro infer_pii_from_name(column_name) %}
  {% if not var("pii_inference_enabled", true) %}{{ return(none) }}{% endif %}
  {% set col = column_name | lower %}
  {% set excludes = var("pii_name_exclude_patterns", chameleon_pii.default_pii_name_exclude_patterns()) %}
  {% for pattern in excludes %}
    {% if modules.re.search(pattern, col) %}
      {{ return(none) }}
    {% endif %}
  {% endfor %}
  {% set patterns = var("pii_name_patterns", chameleon_pii.default_pii_name_patterns()) %}
  {% for pattern, classification in patterns.items() %}
    {% if modules.re.search(pattern, col) %}
      {{ return(classification) }}
    {% endif %}
  {% endfor %}
  {{ return(none) }}
{% endmacro %}
