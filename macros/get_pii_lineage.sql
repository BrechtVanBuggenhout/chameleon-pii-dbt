{#
  Builds the "used where" map by propagating each PII column DOWNSTREAM through the
  dbt DAG. Pure metadata: it walks parent/child edges from `depends_on`, never the data.

  Propagation rule (v0): a PII column is considered to flow into a descendant model
  when that descendant documents a column of the same name. This is conservative and
  cheap; column-renames are not yet followed (see README → roadmap).

  Returns a list of edge dicts: origin field -> downstream model.column, with hop count.
#}
{% macro get_pii_lineage() %}
  {% set edges = [] %}
  {% if not execute %}{{ return(edges) }}{% endif %}

  {% set system = target.type %}
  {% set models = {} %}
  {% set children = {} %}
  {% set name_to_uid = {} %}

  {# Index models and build a parent -> children adjacency map. #}
  {% for uid, node in graph.nodes.items() %}
    {% if node.resource_type == "model" and node.package_name != "chameleon_pii" %}
      {% do models.update({uid: node}) %}
      {% do name_to_uid.update({node.name: uid}) %}
      {% if uid not in children %}{% do children.update({uid: []}) %}{% endif %}
      {% for parent in node.depends_on.nodes %}
        {% if parent not in children %}{% do children.update({parent: []}) %}{% endif %}
        {% do children[parent].append(uid) %}
      {% endfor %}
    {% endif %}
  {% endfor %}

  {% set pii = chameleon_pii.get_pii_columns() %}

  {% for field in pii %}
    {% set origin_uid = name_to_uid.get(field.model_name) %}
    {% if origin_uid is none %}{% continue %}{% endif %}

    {# BFS over descendants, tracking hop distance. namespace() keeps the frontier
       reassignment visible across outer-loop iterations (Jinja for-scope quirk). #}
    {% set visited = [] %}
    {% set ns = namespace(frontier=[(origin_uid, 0)]) %}
    {% for _ in range(0, models | length) %}
      {% if ns.frontier | length == 0 %}{% break %}{% endif %}
      {% set next = [] %}
      {% for pair in ns.frontier %}
        {% set uid = pair[0] %}{% set hops = pair[1] %}
        {% for child_uid in children.get(uid, []) %}
          {% if child_uid not in visited %}
            {% do visited.append(child_uid) %}
            {% set child = models[child_uid] %}
            {% if field.field_name in child.columns %}
              {% do edges.append({
                "source_resource_id": field.resource_id,
                "field_name": field.field_name,
                "classification": field.classification,
                "downstream_resource_id": system ~ ":" ~ child.database ~ "." ~ child.schema ~ "." ~ child.name,
                "downstream_model": child.name,
                "downstream_field": field.field_name,
                "hops": hops + 1
              }) %}
            {% endif %}
            {% do next.append((child_uid, hops + 1)) %}
          {% endif %}
        {% endfor %}
      {% endfor %}
      {% set ns.frontier = next %}
    {% endfor %}
  {% endfor %}

  {{ return(edges) }}
{% endmacro %}
