# AVD Lab - PowerShell Deployment Script
# Run this script from the folder containing avd-lab.bicep

# Connect to Azure (comment out if already connected)
# Connect-AzAccount
# Set-AzContext '<your-subscription-id>'

# Create resource group if it doesn't exist
$resourceGroupName = 'AVDLab'
$location = 'uksouth'

if (-not (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $resourceGroupName -Location $location
    Write-Output "Resource group $resourceGroupName created"
} else {
    Write-Output "Resource group $resourceGroupName already exists"
}

# Prompt for VM admin password securely
$securePassword = Read-Host -Prompt 'VM Admin Password' -AsSecureString

# Deploy
New-AzResourceGroupDeployment `
  -ResourceGroupName $resourceGroupName `
  -TemplateFile '.\avd-lab.bicep' `
  -location $location `
  -prefix 'avd-lab' `
  -goldenImageId '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/images/<image-name>' `
  -vmAdminUsername 'avdadmin' `
  -vmAdminPassword $securePassword `
  -avdUsersGroupId '<object-id-of-avd-users-group>' `
  -vmSize 'Standard_D2as_v6' `
  -vmCount 2 `
  -storageAccountSku 'Premium_LRS' `
  -fslogixProfileSizeGB 20 `
  -fslogixUserCount 4 `
  -Verbose
