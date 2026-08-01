{#
  Fails when a field is AT_RISK, NOT_SHREDDABLE, or UNREGISTERED *and* reaches
  a mart/aggregate layer -- i.e. destroying this field's key would not
  actually make it unreadable everywhere it ended up. pii_shred_readiness
  already computes this verdict (registry + discovery + lineage); this is
  the enforcement step that was missing -- without it, readiness stays a
  report you have to remember to look at, not something a build can fail on.

  Severity defaults to 'warn' so simply installing/upgrading the package
  never breaks a build. Set it to 'error' in CI to enforce:

    vars:
      pii_shred_risk_severity: error
#}
{{ config(severity = var('pii_shred_risk_severity', 'warn')) }}

select *
from {{ ref('pii_shred_readiness') }}
where reaches_mart
  and readiness in ('AT_RISK', 'NOT_SHREDDABLE', 'UNREGISTERED')
