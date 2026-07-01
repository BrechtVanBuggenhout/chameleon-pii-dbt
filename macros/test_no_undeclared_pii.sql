{#
  Generic test: fails when `pii_discovery` contains undeclared PII columns.
  Attach it to the pii_discovery model (see discovery.yml).

  Severity defaults to 'warn' so simply installing the package never breaks a build.
  Set it to 'error' in CI to enforce ("no unprotected PII ships"):

    vars:
      pii_undeclared_severity: error
      pii_undeclared_allowlist: ["raw_users.subscription_name"]  # reviewed false positives
#}
{% test no_undeclared_pii(model) %}
  {{ config(severity = var('pii_undeclared_severity', 'warn')) }}

  {%- set allowlist = var('pii_undeclared_allowlist', []) -%}

  select *
  from {{ model }}
  {%- if allowlist | length > 0 %}
  where concat(table_name, '.', field_name) not in (
    {%- for item in allowlist %}
    '{{ item | replace("'", "''") }}'{% if not loop.last %},{% endif %}
    {%- endfor %}
  )
  {%- endif %}
{% endtest %}
