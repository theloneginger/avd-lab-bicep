using './avd-lab.bicep'

// --- Environment ---
param location = 'uksouth'   // Change to your target region
param prefix = 'avd-lab'

// --- Golden Image ---
// Paste the full resource ID of your managed image or SIG image version, e.g.:
// Managed image:   /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/images/<name>
// SIG version:     /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<definition>/versions/<version>
param goldenImageId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-images/providers/Microsoft.Compute/images/avd-golden-image'

// --- Entra ID Group Object IDs ---
// Azure Portal > Entra ID > Groups > <group name> > Overview > Object ID
param avdUsersGroupId = '00000000-0000-0000-0000-000000000000'

// --- Session Host VMs ---
param vmAdminUsername = 'avdadmin'
param vmSize = 'Standard_D4s_v5'
param vmCount = 2

// --- Storage ---
param storageAccountSku = 'Premium_LRS'
param fslogixProfileSizeGB = 20   // GB per user profile
param fslogixUserCount = 4        // Total number of users - share quota = max(profileSize * userCount, 100 GB)

// --- vmAdminPassword ---
// DO NOT put your password here in plain text.
// Use one of these approaches instead:
//
// Option 1 - Pass at deploy time (recommended for lab):
//   az deployment group create \
//     --resource-group rg-avd-lab \
//     --template-file avd-lab.bicep \
//     --parameters avd-lab.bicepparam \
//     --parameters vmAdminPassword='<your-password>'
//
// Option 2 - Key Vault reference (recommended for production):
//   param vmAdminPassword = getSecret('00000000-0000-0000-0000-000000000000', 'rg-keyvault', 'kv-avdlab', 'vmAdminPassword')
