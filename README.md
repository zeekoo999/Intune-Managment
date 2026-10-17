# IntuneManager


<img width="1361" height="862" alt="image" src="https://github.com/user-attachments/assets/df691829-53ce-4492-948a-eea660a0a1f3" />




Back up, migrate, compare, copy and document **Microsoft Intune** and **Entra ID** configuration — with a modern desktop app and a PowerShell module for automation.

It is a ground-up rebuild inspired by [IntuneManagement](https://github.com/Micke-K/IntuneManagement) by Mikael Karlsson, and it reads that tool's exports, so existing backups keep working.

## What is different

| | IntuneManagement | IntuneManager |
|---|---|---|
| Sign-in | MSAL DLLs, interactive sign-in, consent prompts | App registration with **certificate or secret**, pure REST, nothing to install |
| Setting up an app | Manual app registration and permissions | **Setup assistant** creates the app, adds permissions, grants consent, creates the certificate and saves the profile |
| Entering connection details | Settings dialog | **Paste from Entra** fills the IDs from the app's Overview page; live hints catch common mistakes (e.g. Secret ID pasted instead of Secret Value) |
| Errors from Entra | Raw `AADSTS…` text | Plain-language fix for the common `AADSTS` codes |
| UI | Classic WPF; work runs on the UI thread | Dark/light Fluent-style UI; all Graph work runs in background runspaces, so the window never freezes; Cancel button |
| Throttling / outages | Limited retry | Retries 429/5xx with `Retry-After`, exponential backoff and jitter; token refresh on 401; POST never blindly retried (no duplicates) |
| Export speed | One request per object, one per group | Full objects read with `$batch` (20 per call); groups for the migration table read in one batched pass |
| Import safety | Imports directly | **Preview (dry run)**, per-file validation, conflict handling (Skip / Update / Rename / Replace / Duplicate), Conditional Access imported **Off** by default |
| Failure handling | A failure can stop or leave you guessing | Every object reported; one failure never stops the run; **Retry failed** re-imports only what failed |
| Logging | Text log | Text log **and** structured JSONL, rotation and retention, Graph `request-id`/`client-request-id` on every error, JSON + CSV report for every operation |
| Data fidelity | `ConvertFrom-Json` turns date strings into `DateTime` on PS7 | Custom parser keeps every value byte-for-byte |

## Requirements

- Windows 10/11 or Windows Server with **PowerShell 7.2+** ([install](https://aka.ms/powershell)) for the desktop app.
- The cmdlets also run on macOS and Linux (PowerShell 7.2+). Saved secrets need Windows (DPAPI); elsewhere use a certificate or the `IM_CLIENT_SECRET` environment variable.

## Start

1. Download and extract the folder.
2. Double-click **`Start-IntuneManager.cmd`**.

Files downloaded from the internet are unblocked automatically on start.

## Connect

### Option A — let the assistant create the app (about a minute)

1. Click **Connect** → **Create one for me**.
2. Choose *Certificate (recommended)* or *Client secret*, then **Start**.
3. Click **Copy code and open sign-in page**, paste the code and sign in with a Global Administrator, Privileged Role Administrator or Cloud Application Administrator.
4. The assistant creates the app registration, adds the Graph application permissions, grants admin consent, creates the certificate in *CurrentUser\My* (or a 12-month secret), waits for Entra ID to replicate, and saves a connection profile. Click **Connect now**.

The admin sign-in is used only once, for setup. Day-to-day use is app-only.

### Option B — use an existing app registration

1. Click **Connect** → **I have an app registration**.
2. Open the app's **Overview** page in the Entra admin center, select everything (Ctrl+A, Ctrl+C) and click **Paste from Entra**. The client ID, tenant ID and name are filled in.
3. Pick the certificate from the list (or a `.pfx`), or paste the **secret value**.
4. **Test** shows which permissions are granted and which are missing. **Save and connect**.

Profiles are stored in `%APPDATA%\IntuneManager\profiles.json`. Secrets are encrypted with DPAPI for your Windows account and never written in clear text. The last used profile reconnects automatically on start.

### Permissions (Microsoft Graph, application)

| Permission | Used for |
|---|---|
| DeviceManagementConfiguration.ReadWrite.All | Configuration, compliance, settings catalog, endpoint security, updates, filters |
| DeviceManagementApps.ReadWrite.All | Apps, app protection, app configuration, branding |
| DeviceManagementServiceConfig.ReadWrite.All | Enrollment, Autopilot, terms and conditions, notifications |
| DeviceManagementRBAC.ReadWrite.All | Scope tags, roles |
| DeviceManagementScripts.ReadWrite.All | PowerShell, shell, remediation and compliance scripts |
| DeviceManagementManagedDevices.Read.All | Device categories |
| Group.ReadWrite.All | Reading assignment groups; creating missing groups on import |
| Organization.Read.All | Tenant name |
| *Optional:* Policy.Read.All, Policy.ReadWrite.ConditionalAccess, Application.Read.All, Agreement.ReadWrite.All, Organization.ReadWrite.All, CloudPC.ReadWrite.All, User.Read.All | Conditional Access, named locations, authentication strengths, terms of use, company branding, Windows 365 |

Use read-only variants (`*.Read.All`) if the app should only export, compare and document.

## Export

**Export** (Home or toolbar, Ctrl+E) → choose a folder and object types, or the objects selected in the grid.

```
<folder>\<Tenant>\<yyyy-MM-dd_HHmm>\
  manifest.json          tool, tenant, counts, SHA-256 of every file
  MigrationTable.json    groups/users referenced by assignments
  Groups\*.json          group definitions (incl. dynamic rules) to recreate groups
  <ObjectType>\<name>.json   one file per object, assignments included
  <ObjectType>\<name>.ps1    scripts saved as readable files too
  _Reports\Export_*.json/.csv
```

## Import

**Import** (Ctrl+I) → choose an export folder → **Load**.

1. Every file is parsed and validated. Invalid files are flagged, not fatal. Files edited after export are marked.
2. Untick what you don't want. Objects are ordered by dependency (scope tags → filters → … → apps → policies → Conditional Access → policy sets).
3. **Preview (no changes)** resolves groups and dependencies and shows *Will create / Will update / Skipped* per object, plus groups that would be created.
4. **Import**. Each row shows its result; **Retry failed** re-runs only the failures; **Open report** opens the CSV.

Between tenants, references are mapped automatically: groups (by name, created if missing from `Groups\*.json`), users (by UPN), scope tags, assignment filters, apps (app configuration, ESP, policy sets, dependencies/supersedence), named locations, authentication strengths, reusable settings and custom ADMX definitions. Within the same tenant, ids are kept.

| When an object with the same name exists | |
|---|---|
| Skip it *(default)* | Keep it; its id is still used for references |
| Update it | Overwrite settings and replace assignments |
| Import a renamed copy | Add a suffix, e.g. "(Imported)" |
| Delete and recreate | Requires typing REPLACE |
| Import anyway | Duplicate |

## Compare, copy, delete, document

- **Compare**: baseline export vs the live tenant, or export vs export. Settings are matched by setting id (not position) and assignments by group name, so cross-tenant comparisons are meaningful. Save as HTML or CSV.
- **Copy**: duplicate an object in the tenant under a new name.
- **Delete**: requires typing DELETE; built-in and default objects are protected.
- **Document**: HTML (searchable, dark/light), Word (.docx, no Office needed), Markdown, CSV or JSON. Settings catalog and endpoint security setting names are resolved when connected.

## Logs and reports

- Activity log panel in the app (filter by warnings/errors, copy lines).
- Files in `%APPDATA%\IntuneManager\Logs` (configurable):
  - `IntuneManager_yyyyMMdd.log` — readable text
  - `IntuneManager_yyyyMMdd.jsonl` — one JSON entry per line (time, level, category, operation id, error type, HTTP status, Graph error code, `request-id`, `client-request-id`)
  - `Reports\*.json/.csv` — every object of every operation with action, status, source/target id and request id
- Daily files, 20 MB rollover, retention (default 30 days).

## Automation (cmdlets)

```powershell
Import-Module .\IntuneManager.psd1

# Connect with a saved profile, or directly
Connect-IMTenant -ProfileName 'Contoso PROD'
Connect-IMTenant -TenantId contoso.onmicrosoft.com -ClientId <app-id> -CertificateThumbprint <thumbprint>

# Nightly backup of everything the app may read
Initialize-IMLogging -Directory D:\IntuneBackup\Logs
$r = Export-IMObjects -Path D:\IntuneBackup
if ($r.Failed) { exit 1 }

# Preview, then import into another tenant
Connect-IMTenant -ProfileName 'Fabrikam TEST'
Import-IMObjects -Path D:\IntuneBackup\Contoso\2026-10-17_0200 -WhatIf
Import-IMObjects -Path D:\IntuneBackup\Contoso\2026-10-17_0200 -ConflictAction Update

# Re-run only what failed
Import-IMObjects -Path <export> -File (Get-IMFailedFiles -ReportPath <report.json>)

# Drift report and documentation
Compare-IMObjects -ReferencePath <baseline export> | Where-Object Status -ne 'Identical'
New-IMDocumentation -Live -Format Word -OutputPath D:\Docs
```

`Get-Command -Module IntuneManager` lists all commands; `Get-Help <command> -Full` shows parameters and examples.

## Object types

Configuration profiles, Settings catalog (incl. settings-catalog endpoint security and baselines), Administrative templates (incl. custom ADMX), imported ADMX files, BIOS configurations, Properties catalog, device categories, Windows 365 provisioning and user settings · Compliance policies (classic and settings catalog), compliance scripts, notification templates · Endpoint security (template-based), reusable settings · PowerShell scripts, macOS shell scripts, macOS custom attributes, Remediations · Update rings, feature, quality and driver updates · Autopilot, enrollment status page, enrollment restrictions, co-management, Apple enrollment types, ADE profiles · Apps (with dependencies/supersedence and Win32 content), app protection, app configuration (managed apps/devices), Android OEMConfig, policy sets · Scope tags, assignment filters, Intune roles (with role assignments), terms and conditions, Company Portal branding · Conditional Access, named locations, authentication strengths and contexts, terms of use, company branding.

## Known limits

- **Win32 app content**: Intune never returns content encryption keys. Content is uploaded on import when the `.intunewin` is next to the export file. Content can be exported only for apps uploaded with this tool (it keeps the keys).
- **Store/VPP apps** are synced from a token or store and cannot be created through Graph; they are skipped with a reason.
- **Encrypted OMA-URI values** are decrypted at export when possible; values that cannot be decrypted won't work in another tenant.
- **Template-based endpoint security** policies whose template Microsoft has retired cannot be created any more; recreate them as Settings catalog policies.
- **Conditional Access** imports as *Off* unless you choose otherwise. Users that don't exist in the target are removed from the policy and reported.

## Troubleshooting

| Message | Fix |
|---|---|
| The client secret is not valid (AADSTS7000215) | Paste the secret **Value**, not the Secret ID |
| The client secret has expired (AADSTS7000222) | Create a new secret and edit the profile |
| The app (client) ID was not found (AADSTS700016) | Wrong client ID/tenant, or the app is in another tenant |
| The certificate was rejected (AADSTS700027) | Upload the certificate's public key (.cer) to the app |
| Access denied (403) for an object type | Add the permission shown and grant admin consent; the home page lists what's missing |
| Throttled (429) after retries | Raise *Retries* in Settings or run again later; the report shows what to retry |

Send the `request-id` from the log or report to Microsoft support for Graph errors.

## Tests

```powershell
pwsh -File .\Tests\Run-Tests.ps1      # engine: export, import, mapping, conflicts, retries, logging, compare, docs
pwsh -File .\Tests\Run-JobTests.ps1   # background job infrastructure used by the app
```

The tests run against an in-memory simulated Graph tenant (including injected throttling and errors); no tenant or network is needed.

## License

MIT. Inspired by and file-compatible with [IntuneManagement](https://github.com/Micke-K/IntuneManagement) (MIT) by Mikael Karlsson.
