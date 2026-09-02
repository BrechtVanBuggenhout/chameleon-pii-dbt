-- stg_ci_json_probe.payload only has EMAIL and SSN planted. JSON's own
-- structural characters ({}:,[]"), the benign `note` text, and the boolean
-- `"verified":true` value must not trigger a spurious PHONE/CREDIT_CARD/IP
-- match once the column is flattened with TO_JSON_STRING for scanning.
-- BigQuery-only, same reasoning as the sibling JSON assertions.
{{ config(enabled = (target.type == 'bigquery')) }}
select 'unexpected pattern match on JSON payload: ' || pattern as failure
from {{ ref('pii_content_findings') }}
where table_name = 'stg_ci_json_probe' and column_name = 'payload'
  and pattern not in ('EMAIL', 'SSN')
