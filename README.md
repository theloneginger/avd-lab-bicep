# AVD Lab — Bicep Deployment

A fully automated Azure Virtual Desktop environment deployable either from the **Azure Portal** (wizard UI) or via **PowerShell** (code). Built as a portfolio piece to demonstrate end-to-end AVD infrastructure as code.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Ftheloneginger%2Favd-lab-bicep%2Fmain%2Favd-lab.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Ftheloneginger%2Favd-lab-bicep%2Fmain%2FcreateUiDefinition.json)

---

## What gets deployed

| Resource | Detail |
|---|---|
| Virtual Network | 10.0.0.0/16 with AVD and storage subnets |
| NAT Gateway | Secure outbound internet — no public IPs on VMs |
| NSGs | AVD and storage subnets locked down |
| Storage Account | Azure Files Premium v2 |
| FSLogix Share | Quota calculated from profile size × user count |
| Private Endpoint | Storage accessed privately over the VNet |
| Private DNS Zone | `privatelink.file.core.windows.net` linked to VNet |
| Host Pool | Pooled, BreadthFirst, Entra ID-joined, SSO enabled |
| App Group | Desktop App Group |
| Workspace | Linked to App Group |
| Session Hosts | Configurable number of VMs, Trusted Launch, no public IP |
| RBAC | AVD Users granted Desktop Virtualization User + VM User Login + FSLogix SMB roles |

---

## FSLogix authentication

This deployment uses **storage account key authentication** for FSLogix profile containers. The storage account key is automatically retrieved at deploy time and stored in Windows Credential Manager on each session host — no manual steps required after deployment.

> **Note:** For production environments, [Entra Kerberos authentication](entra-kerberos/README.md) is recommended as it uses identity-based access rather than a shared key. See the `entra-kerberos` folder for an alternative deployment that implements this.

---

## Pre-requisites

Before deploying, ensure you have:

1. **A golden VM image** — either a Managed Image or a Shared Image Gallery version in the same subscription. It is recommended to install FSLogix into the golden image before capturing it as this saves deployment time — however it is not required as the deployment will automatically download and install FSLogix if it is not detected on the VM
2. **AVD Users** — an Entra ID security group containing your AVD users
3. **AVD Devices** — an Entra ID security group for Intune policy targeting (no action needed at deploy time)

That's it — no post-deployment configuration is required.

---

## Deployment — Option 1: Azure Portal wizard

Click the **Deploy to Azure** button at the top of this page. This opens a multi-step wizard in the Azure Portal with:

- Resource prefix text box
- Golden image resource ID with format validation
- VM count dropdown and size selector
- Password field with complexity validation and confirmation
- AVD Users group Object ID with GUID format validation
- FSLogix profile size and user count dropdowns with share quota calculation
- Storage redundancy dropdown (LRS / ZRS)
- Full summary page before deploying

---

## Deployment — Option 2: PowerShell

### 1. Clone the repository

```powershell
git clone https://github.com/theloneginger/avd-lab-bicep.git
cd avd-lab-bicep
```

### 2. Fill in your values

Edit `avd-lab.bicepparam`:

```bicep
param goldenImageId        = '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/images/<image-name>'
param avdUsersGroupId      = '<object-id-of-avd-users-group>'
param fslogixProfileSizeGB = 20
param fslogixUserCount     = 4
```

### 3. Connect to Azure

```powershell
Connect-AzAccount
Set-AzContext -SubscriptionId '<your-subscription-id>'
```

### 4. Create the resource group

```powershell
New-AzResourceGroup -Name 'rg-avd-lab' -Location 'uksouth'
```

### 5. Preview changes (optional but recommended)

```powershell
$securePassword = Read-Host -Prompt 'VM Admin Password' -AsSecureString

New-AzResourceGroupDeployment `
  -ResourceGroupName 'rg-avd-lab' `
  -TemplateFile '.\avd-lab.bicep' `
  -TemplateParameterFile '.\avd-lab.bicepparam' `
  -vmAdminPassword $securePassword `
  -WhatIf
```

### 6. Deploy

```powershell
New-AzResourceGroupDeployment `
  -ResourceGroupName 'rg-avd-lab' `
  -TemplateFile '.\avd-lab.bicep' `
  -TemplateParameterFile '.\avd-lab.bicepparam' `
  -vmAdminPassword $securePassword `
  -Verbose
```

---

## FSLogix share quota calculation

The file share quota is calculated automatically:

```
quota = max(profileSizeGB × userCount, 100)
```

Azure Files Premium has a **minimum share size of 100 GB**. Examples:

| Profile size | Users | Calculated | Actual quota |
|---|---|---|---|
| 20 GB | 4 | 80 GB | **100 GB** (floor applied) |
| 20 GB | 6 | 120 GB | **120 GB** |
| 30 GB | 10 | 300 GB | **300 GB** |

---

## Repository structure

| File/Folder | Purpose |
|---|---|
| `avd-lab.bicep` | Main Bicep template — storage key auth |
| `avd-lab.json` | Compiled ARM JSON — used by the Deploy to Azure button |
| `avd-lab.bicepparam` | Parameter values for PowerShell deployment |
| `createUiDefinition.json` | Portal wizard UI — dropdowns, validation |
| `README.md` | This file |
| `entra-kerberos/` | Alternative deployment using Entra Kerberos authentication |
