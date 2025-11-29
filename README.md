

Table of contents
- [Executive summary](#executive-summary)
- [Business value](#business-value)
- [Solution overview](#solution-overview)
- [Design principles](#design-principles)
- [Architecture (logical)](#architecture-logical)
- [Deployment flow](#deployment-flow)
- [Operational considerations](#operational-considerations)
- [Deliverable checklist](#deliverable-checklist)
- [Troubleshooting and known failure modes](#troubleshooting-and-known-failure-modes)
- [Repository layout](#repository-layout)
- [Next steps](#next-steps)

---

## Executive summary

Purpose: provide a repeatable, auditable, policy-driven approach to ensure
Azure virtual machines are consistently protected by Azure Backup across
multiple regions.

Scope: subscription-level orchestration that provisions Recovery Services
Vaults (one per region), backup policies, a single remediation identity,
and per-region policy assignments that remediate VMs tagged for
protection.

## Business value

- Compliance: enforces backup standards and retention rules across the
	estate.
- Operational efficiency: reduces manual configuration and human error
	by using policy-based remediation.
- Cost control: centralized retention profiles and schedules reduce
	accidental over-retention and simplify chargeback.

## Solution overview

- Deploy a Recovery Services Vault per region and attach consistent
	backup policies (daily/weekly with optional long-term retention).
- Provision a single User Assigned Managed Identity (UAI) used by the
	remediation workflow.
- Create per-region policy assignments that remediate VMs matching a
	configurable tag and enroll them in the correct vault policy.

## Design principles

- Deterministic inputs: `main.bicep` expects explicit arrays for
	`regions`, `rgNames`, `vaultNames`, `uaiNames`, and
	`backupPolicyNames` so deployments are predictable and index-aligned.
- Reuse of AVM: core resource modules are sourced from the Azure Verified
	Modules registry for maintainability and consistent best-practice
	implementations.
- Minimal blast radius: policy remediations are scoped per-region and
	target only VMs with the configured tag.
- Idempotency: template and remediation flows are safe to re-run.

Architecture (logical)
- Subscription orchestrator (`main.bicep`) calls AVM modules to create:
	- Resource groups (as provided in `rgNames`)
	- Recovery Services Vaults (`vaultNames`) with `backupPolicies` attached
	- A single UAI (first entry in `uaiNames`) and subscription-scoped role assignment
	- Local module `assignCustomCentralBackupPolicy.bicep` to assign policy and create remediation

### Architecture (logical)

This section provides a concise, non-SVG description of the architecture and flow.

CI / Operator
  ↓
`main.bicep` (subscription orchestrator)
  ↓
Resource Groups (per-region)  →  Recovery Services Vaults  →  Backup Policies
  ↓
`assignCustomCentralBackupPolicy` (subscription assignment)
  ↓
Policy Remediation (DeployIfNotExists)  →  Tagged VMs enrolled into Backup

Notes:
- A single User Assigned Managed Identity (UAI) is used as the remediation principal to avoid race conditions from multiple UAIs.
- `main.bicep` uses index-aligned arrays (e.g., `regions`, `rgNames`, `vaultNames`) to make deployments deterministic and avoid `copyIndex()` leakage in compiled templates.


Deployment flow
1. Author parameters in `parameters/main.parameters.json` (canonical defaults) and provide per-run overrides as needed.
2. Build Bicep (resolve AVM modules):
```powershell
az bicep build --file .\main.bicep --outfile .\bicep-build\main.json
```
3. Run the deploy script (merges params, emits typed ARM parameter file, deploys compiled template):
```powershell
powershell -File .\scripts\Deploy-BackupInfra.ps1 -SubscriptionId <SUB_ID> -DeploymentLocation <location> -Regions "<region1,region2,..>"
```
4. Assign policy and start remediation (per-region):
```powershell
powershell -File .\scripts\Start-BackupRemediation.ps1 -SubscriptionId <SUB_ID> -Regions "<region1,region2,..>" -TagName <tag> -TagValue <value>
```

Operational considerations
- Parameter discipline: keep canonical values in `parameters/main.parameters.json`. Provide only run-specific overrides from CI to avoid drift.
- Naming: `main.bicep` expects position-aligned arrays — ensure `rgNames[i]` matches `regions[i]` and `vaultNames[i]`.
- Permissions: the deploying principal must be able to create subscription role assignments or an operator must create the role for the UAI.
- Compiled artifacts: remove stale `bicep-build/main.json` if you see `copyIndex`-related template validation errors; run a fresh `az bicep build`.

Deliverable checklist (pre-deploy)
- Confirm `parameters/main.parameters.json` contains desired defaults (schedules/retention/tags).
- Verify `regions`, `rgNames`, `vaultNames`, `uaiNames`, `backupPolicyNames` arrays are correct and index-aligned.
- Ensure the deployment account has `Owner` or `User Access Administrator` for role operations.

Troubleshooting and known failure modes
- InvalidTemplate / copyIndex: delete `bicep-build/main.json` and rebuild — older compiled templates may include invalid template expressions.
- ResourceGroupNotFound: fix `rgNames` to match actual target RG names or ensure the RGs are created prior to remediation runs.
- FailedIdentityOperation: if the UAI was deleted, either recreate it, update `uaiNames`, or adjust the parameter file to an existing UAI.
- Active remediation update failure: remediation jobs must be completed or canceled before updating certain properties; the remediation script handles active states gracefully but manual intervention can be required.

Repository layout (quick map)
- `main.bicep` — subscription-scoped orchestrator (AVM-driven)
- `parameters/main.parameters.json` — canonical defaults (schedules, retention, tags)
- `modules/assignCustomCentralBackupPolicy.bicep` — local assignment + remediation module
- `policy-definitions/` — policy rule JSON and full policy JSON (preserved when needed)
- `scripts/Deploy-BackupInfra.ps1` — builds and deploys infra; emits `main-params.json`
- `scripts/Start-BackupRemediation.ps1` — assigns policy per-region and triggers remediations

Next steps I can take
- Produce a production-ready `parameters/main.parameters.json` with index-aligned arrays and sensible defaults for your environment.
- Run `az bicep build` here and surface any build-time issues found.
- Draft a one-page runbook for run/rollback/verification suitable for operations handoff.

---

If you want this delivered as a presentation slide deck or a short one-page architecture diagram, tell me your audience (operations, security, or exec) and I will produce it.

