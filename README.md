
````markdown
## Multi-Region Azure VM Backup — Architect Brief and Delivery Notes

Executive summary
- Purpose: provide a repeatable, auditable, policy-driven approach to ensure Azure VMs are consistently protected by Azure Backup across multiple regions.
- Scope: subscription-level orchestration that provisions Recovery Services Vaults, backup policies, a single remediation identity, and policy assignments that remediate VMs with a configurable tag.

Business value
- Compliance: enforces backup standards and retention rules across the estate.
- Operational efficiency: reduces manual configuration and human error by using policy-based remediation.
- Cost control: centralized retention profiles and schedules reduce accidental over-retention.

Solution overview (what it does)
- Deploys one Recovery Services Vault per region and attaches consistent backup policies (Daily/Weekly schedules and long-term retention where configured).
- Provisions one User Assigned Managed Identity (UAI) used as the remediation principal for the DeployIfNotExists policy.
- Creates per-region policy assignments that run remediations to enroll VMs matching the tag into the appropriate vault policy.

Design principles
- Deterministic inputs: `main.bicep` requires explicit arrays for `regions`, `rgNames`, `vaultNames`, `uaiNames`, and `backupPolicyNames` so deployments are predictable.
- Reuse AVM: core resource modules are sourced from the Azure Verified Modules registry for maintainability and consistent best-practice implementations.
- Minimal blast radius: policy remediations are scoped per-region and target only VMs with the configured tag.
- Idempotency: deployments and remediation runs are designed to be repeatable and safe to re-run.

Architecture (logical)
- Subscription orchestrator (`main.bicep`) calls AVM modules to create:
	- Resource groups (as provided in `rgNames`)
	- Recovery Services Vaults (`vaultNames`) with `backupPolicies` attached
	- A single UAI (first entry in `uaiNames`) and subscription-scoped role assignment
	- Local module `assignCustomCentralBackupPolicy.bicep` to assign policy and create remediation

### Architecture diagram

Below is a logical diagram showing the flow from CI/operator to subscription orchestration and remediation.

```mermaid
flowchart LR
  CI[CI / Operator] -->|build & params| BICEP[main.bicep (subscription orchestrator)]
  BICEP --> RG[Resource Groups (per-region)]
  RG --> Vaults[Recovery Services Vaults]
  Vaults --> Policies[Backup Policies (per-vault)]
  BICEP --> UAI[User Assigned Identity (single, remediation principal)]
  Policies --> Assign[assignCustomCentralBackupPolicy Module]
  Assign --> Remediation[Policy Remediation (DeployIfNotExists)]
  Remediation --> VMs[Tagged VMs]
  CI --> Scripts[Deploy-BackupInfra.ps1 / Start-BackupRemediation.ps1]
  Scripts --> BICEP
  UAI --> Assign
  Vaults --> Assign
```

If your renderer does not support Mermaid, this ASCII fallback illustrates the same flow:

```
CI/Operator
	|
	v
main.bicep (subscription orchestrator) <--- scripts (build/params/deploy)
	|
	+--> Resource Group (per region)
			 |
			 +--> Recovery Services Vault (per region)
					 |
					 +--> Backup Policies (attached to vault)
					 |
					 +--> assignCustomCentralBackupPolicy (uses UAI)
								  |
								  +--> Policy Remediation (Enroll tagged VMs)
```


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

