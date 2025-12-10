
## Multi-Region Azure VM Backup Automation

### 1. Overview
This repository implements a policy-driven, multi-region Azure Backup platform that enables and remediates protection for tagged Virtual Machines. The solution is designed for operational predictability, auditability and minimal identity sprawl. Key implementation choices include:

- A single shared User Assigned Managed Identity (UAI) created in the central resource group (`rsv-rg-central`); this identity is used to perform remediation across all targeted regions.
- Subscription-scoped Bicep orchestration (`main.bicep`) built from modular components for vaults, backup policies and role assignments.
- Idempotent PowerShell helpers for infrastructure deployment and policy remediation suitable for CI or ad-hoc execution.

The README preserves an operator-friendly, stepwise layout while documenting the current deterministic behavior and operational prerequisites.

---

## Table of contents

1. Quick snapshot
2. Why this design (architecture rationale)
3. Architecture (logical view)
4. Repository layout (concise)
5. Parameters and pipeline notes
6. Recommended hardening
7. Summary

---

## 1 — Quick snapshot

- Target: programmatic enablement of Azure Backup for Virtual Machines that match a configurable tag name/value, across one or more regions.
- Deployment: `main.bicep` (subscription scope) creates the regional Recovery Services Vaults (RSVs), backup policies and a single shared UAI used for remediation.
- Remediation: a custom `DeployIfNotExists` policy (`Custom-CentralVmBackup-AnyOS`) is assigned and remediation jobs are orchestrated by `Start-BackupRemediation.ps1`.

This approach provides centralized control, consistent vault and policy configuration per region, and auditable remediation operations.

---

## 2 — Why this design (architecture rationale)

- Regional RSVs: keep backup data co-located with VMs to meet recovery and compliance requirements.
- Policy-driven remediation: use Azure Policy `DeployIfNotExists` for declarative, auditable and repeatable remediation runs.
- Single shared UAI: minimizes managed identity proliferation and reduces RBAC management surface while preserving an auditable principal for remediation actions.
- Modular Bicep + deterministic scripts: enables reproducible deployments and simpler operational troubleshooting.

---

## 3 — Architecture (logical view)

```
                      +-------------------------+
                      |   CI (GitHub / ADO)    |
                      +-----------+-------------+
                                  |
                                  v
                    +-------------------------------+
                    | Subscription / main.bicep     |
                    | - ensure rsv-rg-central RG    |
                    | - create rsv-<region> vaults  |
                    | - create policies & outputs   |
                    +-------------------------------+
                                  |
      +---------------------------+---------------------------+
      |                                                       |
      v                                                       v
  Recovery Services Vaults (rsv-<region>)                Azure Policy
  - All vaults in single rsv-rg-central RG               - Custom DeployIfNotExists
  - backup policies (daily/weekly)                       - Assignment (uses single shared UAI)
  - protectedItems (region-specific)
```

---

## 4 — Repository layout (concise)

- `main.bicep` — subscription-scoped orchestration and outputs (vault IDs, policy IDs, UAI resource id/principal id).
- `modules/` — Bicep modules: `recoveryVault`, `backupPolicy`, `userAssignedIdentity`, `roleAssignment`, `assignCustomCentralBackupPolicy`, `backupAuditPolicy`.
- `policy-definitions/` — `customCentralVmBackup.rules.json` and `customCentralVmBackup.full.json` (policy artifacts).
- `scripts/` — PowerShell helpers:
  - `Deploy-BackupInfra.ps1` — builds/deploys `main.bicep`. The script pre-creates the central `rsv-rg-central` resource group (to avoid nested deployment failures), supports a `-NoArtifacts` switch and central parameters file usage.
  - `Start-BackupRemediation.ps1` — ensures the shared UAI exists in the central resource group (`rsv-rg-central`), attempts subscription-level role assignment (if caller has permission), assigns the custom policy and triggers remediations. The script supports `-NoArtifacts` and deterministic fallback resolution for the UAI.
- `parameters/` — centralized parameter file(s) such as `parameters/main.parameters.json` used by CI pipelines.
- `Pipeline/` and `.github/workflows/` — CI definitions for GitHub Actions and Azure DevOps.


---


## 5 — Parameters and pipeline notes

Composite retention profile (convenience):

```
DailyDays|WeeklyWeeks|YearlyYears|TagName|TagValue
Example: 14|5|0|backup|true
```

Pipeline variables (high level):

| Parameter | Meaning |
|---|---|
| `Regions` | Comma-separated list of target regions (e.g., `westeurope,northeurope`) |
| `deploymentLocation` | Location for subscription deployment metadata (e.g., `westeurope`) |
| `backupFrequency` | `Daily` / `Weekly` / `Both` |
| `retentionProfile` | Composite retention + tag value (see above) |
| `enableAutoRemediation` | `true` to assign and trigger policy remediation |

CI integration:
- GitHub Actions and Azure DevOps pipelines included in this repo illustrate building, deploying and optionally running remediation. Use the centralized parameter file for predictable runs and to avoid embedding secrets in pipeline YAML.

---

## 6 — Recommended hardening

- Enforce least privilege: prefer a deployment principal scoped to the minimal operations required. For subscription-level role assignments you may use a privileged onboarding step handled by an operator or a separate security pipeline.
- Protect vault access: apply private endpoints, firewall rules, and network rules according to your security posture; the `recoveryVault` module supports configurable networking patterns.
- Audit and monitor remediation: use Azure Policy Insights and Activity Logs to track remediation operations performed by the shared UAI.

---

## 7 — Summary

This solution delivers an auditable, and scalable way to ensure that every tag-targeted VM is reliably protected with regionally co-located Recovery Services Vaults — reducing operational risk and simplifying compliance. By combining subscription-scoped Bicep orchestration, modular templates, and idempotent PowerShell helpers with a single deterministically-created shared User Assigned Managed Identity, operators get centralized control, predictable deployments, and significantly reduced RBAC overhead. Policy-driven remediation (DeployIfNotExists) provides automated, auditable enforcement with minimal human intervention, while regional vaults preserve data residency and recovery SLAs. The outcome is faster onboarding, fewer missed backups, simpler audits, and lower operational costs — a repeatable pattern you can deploy at scale to improve recovery readiness and free your teams to focus on higher-value work.



