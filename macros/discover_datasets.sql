{#-
  Auto-discovers the datasets this project touches, so pii_discovery_datasets and
  pii_content_scan_datasets don't have to be hand-maintained (or grepped out of every
  sources.yml by hand). Walks the dbt graph (metadata only, zero warehouse queries):

    - every (database, schema) behind a declared source() — i.e. every dataset listed
      across the project's sources.yml files, INCLUDING ones that override `database:`
      to point at a different GCP project / Snowflake database than the target, and
    - every (database, schema) any model in the project resolves to.

  Returns fully-qualified "<database>.<schema>" strings (GCP project for BigQuery,
  database for Snowflake) so cross-project/cross-database sources survive — a bare
  schema name would silently collapse back into the target project, which is exactly
  what made the old [target.schema]-only default single-project and easy to fall out
  of sync with. pii_information_schema_columns() below parses both this qualified
  form and a plain schema name (implicitly target.database) for backward
  compatibility with hand-written pii_discovery_datasets lists.

  Falls back to [target.schema] if the graph has neither (e.g. a brand-new project
  with no sources declared yet). Explicit `pii_discovery_datasets` /
  `pii_content_scan_datasets` vars always take precedence over this.
-#}
{% macro pii_discovered_datasets() %}
  {% if not execute %}{{ return([target.schema]) }}{% endif %}

  {% set datasets = [] %}

  {% for node in graph.sources.values() %}
    {% if node.schema %}
      {% set qualified = (node.database or target.database) ~ '.' ~ node.schema %}
      {% if qualified not in datasets %}{% do datasets.append(qualified) %}{% endif %}
    {% endif %}
  {% endfor %}

  {% for node in graph.nodes.values() %}
    {% if node.resource_type == "model" and node.package_name != "chameleon_pii" %}
      {% if node.schema %}
        {% set qualified = (node.database or target.database) ~ '.' ~ node.schema %}
        {% if qualified not in datasets %}{% do datasets.append(qualified) %}{% endif %}
      {% endif %}
    {% endif %}
  {% endfor %}

  {% if datasets | length == 0 %}
    {{ return([target.schema]) }}
  {% endif %}

  {% set target_qualified = target.database ~ '.' ~ target.schema %}
  {% if target_qualified not in datasets %}
    {% do datasets.append(target_qualified) %}
  {% endif %}

  {{ return(datasets) }}
{% endmacro %}


{#-
  dbt run-operation pii_list_datasets

  Prints every dataset chameleon_pii would scan by default: every source() dataset
  declared across the project's sources.yml files (cross-project ones included),
  every model's dataset, and the target dataset. This is the list-of-resources-to-
  declare the Chameleon installer can shell out to instead of asking a user to
  hand-type (or hand-grep) dataset names.
-#}
{% macro pii_list_datasets() %}
  {% if not execute %}{{ return('') }}{% endif %}
  {% set datasets = chameleon_pii.pii_discovered_datasets() %}
  {{ log('chameleon_pii: discovered ' ~ (datasets | length) ~ ' dataset(s) from sources.yml + models:', info=True) }}
  {% for d in datasets %}
    {{ log('  - ' ~ d, info=True) }}
  {% endfor %}
  {{ return(datasets) }}
{% endmacro %}
