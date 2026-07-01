{{ config(
    materialized='table',
    maximum_bytes_billed=var('pii_content_max_bytes_billed', 1000000000)
) }}

{#-
  Content/value scan findings. OFF by default — set var pii_content_scan_enabled=true
  and run on a schedule (not every build). See macros/scan_content.sql for the guardrails.
-#}

{{ chameleon_pii.build_content_findings_sql() }}
