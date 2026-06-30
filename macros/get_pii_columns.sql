{#
  Walks every model in the dbt graph and returns a list of PII field records.
  This is pure metadata introspection — it reads manifest/graph only and issues
  ZERO warehouse queries. Safe to run on every build.

  A column is included if either:
    - it carries `meta.pii` in schema.yml (DECLARED), or
    - inference is enabled and its name matches a pattern (INFERRED).

  Each record is a dict the registry/lineage models turn into rows.
#}
{% macro get_pii_columns() %}
  {% set records = [] %}
  {% if not execute %}{{ return(records) }}{% endif %}

  {% set system = target.type %}

  {% set exclude_models = var("pii_exclude_models", []) %}

  {% for node in graph.nodes.values() %}
    {% if node.resource_type != "model" %}{% continue %}{% endif %}
    {# Never introspect this package's own registry models. #}
    {% if node.package_name == "chameleon_pii" %}{% continue %}{% endif %}
    {% if node.name in exclude_models %}{% continue %}{% endif %}

    {% set resource_id = system ~ ":" ~ node.database ~ "." ~ node.schema ~ "." ~ node.name %}
    {% set layer = chameleon_pii.infer_layer(node) %}
    {% set owner = node.meta.get("chameleon", {}).get("owner", "dbt") %}

    {% for col_name, col in node.columns.items() %}
      {% set declared = col.meta.get("pii") %}

      {% if declared %}
        {% set classification = declared.get("classification", "SENSITIVE") %}
        {% set record = {
          "resource_id": resource_id,
          "model_name": node.name,
          "system": system,
          "layer": layer,
          "owner": owner,
          "field_name": col_name,
          "classification": classification,
          "handling": declared.get("handling", chameleon_pii.default_handling(classification)),
          "confidence": "DECLARED",
          "detection_method": "DECLARED",
          "required_in_mart": declared.get("required_in_mart", false)
        } %}
        {% do records.append(record) %}

      {% else %}
        {% set inferred = chameleon_pii.infer_pii_from_name(col_name) %}
        {% if inferred %}
          {% set record = {
            "resource_id": resource_id,
            "model_name": node.name,
            "system": system,
            "layer": layer,
            "owner": owner,
            "field_name": col_name,
            "classification": inferred,
            "handling": chameleon_pii.default_handling(inferred),
            "confidence": var("pii_inference_confidence", "INFERRED_HIGH"),
            "detection_method": "NAME_INFERENCE",
            "required_in_mart": false
          } %}
          {% do records.append(record) %}
        {% endif %}
      {% endif %}
    {% endfor %}
  {% endfor %}

  {{ return(records) }}
{% endmacro %}
