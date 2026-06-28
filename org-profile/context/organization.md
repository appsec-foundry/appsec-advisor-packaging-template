# Acme Corp — Organization Context

Replace this stub with a short, factual description of your organization,
maintained by the AppSec or platform team. This file is loaded as reference data into
threat model analyses — it can inform findings, but it cannot change severity
rules, QA gates, schemas, permissions, or tool behavior.

Acme Corp operates a multi-tenant B2B SaaS platform. Critical flows include
tenant onboarding, administrative configuration changes, API-key based service
integrations, billing exports, and support-assisted account recovery.

Baseline assumptions for reviews:

- Workforce identity uses SSO and MFA.
- Production access is mediated through CI/CD and audited break-glass access.
- Customer tenants are isolated by tenant ID and data-region controls.
- Internet-facing APIs require authentication except documented health checks
  and public metadata endpoints.
- Security events that affect identity, authorization, secrets, payment data,
  or tenant boundaries must be logged centrally.
