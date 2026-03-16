// =============================================================================
// AVD Lab - Full Deployment
// Deploys: Networking, Storage (FSLogix via Azure Files v2), AVD Host Pool,
//          App Group, Workspace, 2x Session Hosts (Entra-joined, Intune-enrolled)
// Pre-requisites:
//   - Golden image stored as a Managed Image or Shared Image Gallery version
//   - Entra ID group 'AVD Users'   (provide its Object ID via avdUsersGroupId)
//   - Entra ID group 'AVD Devices' (used for Intune policy targeting - no Bicep action needed)
// =============================================================================

// --- Parameters ---
param location string = resourceGroup().location
param prefix string = 'avd-lab'

// Golden image - supply EITHER a managed image resource ID OR a SIG image version ID
param goldenImageId string

// Local admin on the session hosts (password passed at deploy time - never hard-code)
param vmAdminUsername string = 'avdadmin'

// utcNow() is only valid as a parameter default - used to set host pool token expiry
param baseTime string = utcNow()
@secure()
param vmAdminPassword string

// Object ID of the Entra ID 'AVD Users' security group
param avdUsersGroupId string

// VM sizing
param vmSize string = 'Standard_D4s_v5'
param vmCount int = 2

// Storage
param storageAccountSku string = 'Premium_LRS'  // Required for Azure Files Premium (v2)

@description('Maximum size of each FSLogix profile in GB')
@minValue(1)
param fslogixProfileSizeGB int = 20

@description('Number of users who will have FSLogix profiles')
@minValue(1)
param fslogixUserCount int = 4

// Calculated share quota - total profile space with a 100 GB floor (Azure Files Premium minimum)
var fslogixShareQuotaGB = max(fslogixProfileSizeGB * fslogixUserCount, 100)

// Tags applied to every resource
var tags = {
  environment: 'lab'
  project: 'avd'
}

// =============================================================================
// NETWORKING
// =============================================================================

// 1. Public IP for the NAT Gateway (Standard SKU is mandatory)
resource natPublicIP 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${prefix}-nat-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// 2. NAT Gateway - secure outbound internet for session hosts (no public IPs on VMs)
resource natGateway 'Microsoft.Network/natGateways@2023-09-01' = {
  name: '${prefix}-nat-gw'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIpAddresses: [
      { id: natPublicIP.id }
    ]
  }
}

// 3. NSG for AVD host subnet
//    Allows RDP from the vnet only; blocks direct internet inbound
resource avdNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-avd-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-Inbound-VNet'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Allow-AVD-ServiceTag'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'WindowsVirtualDesktop'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

// 4. NSG for storage subnet (locks down to vnet traffic only)
resource storageNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-storage-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SMB-From-AVD-Subnet'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '10.0.1.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '445'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// 5. Virtual Network with two subnets
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'snet-avd-hosts'
        properties: {
          addressPrefix: '10.0.1.0/24'
          natGateway: { id: natGateway.id }
          networkSecurityGroup: { id: avdNsg.id }
        }
      }
      {
        name: 'snet-storage'
        properties: {
          addressPrefix: '10.0.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: { id: storageNsg.id }
        }
      }
    ]
  }
}

// Convenience references to subnet resource IDs
var avdSubnetId = vnet.properties.subnets[0].id
var storageSubnetId = vnet.properties.subnets[1].id

// =============================================================================
// STORAGE - FSLogix via Azure Files Premium v2
// =============================================================================

// 6. Storage Account (Premium FileStorage = Azure Files v2 / NFS + SMB large-scale)
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${replace(prefix, '-', '')}sa${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: storageAccountSku }      // Premium_LRS required for Premium Files
  kind: 'FileStorage'                   // FileStorage kind = Azure Files v2
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true           // SMB Kerberos still needs this for initial mount
    publicNetworkAccess: 'Disabled'      // All access via Private Endpoint only
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    largeFileSharesState: 'Enabled'      // Enables up to 100 TiB shares
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'  // Entra Kerberos - no AD DS required
    }
  }
}

// 7. Azure Files share for FSLogix profile containers
resource fslogixShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: '${storageAccount.name}/default/fslogix-profiles'
  properties: {
    shareQuota: fslogixShareQuotaGB  // Calculated: profileSizeGB * userCount, min 100 GB
    enabledProtocols: 'SMB'
  }
}

// 8. Private DNS Zone for storage (resolves storage.windows.net privately)
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  #disable-next-line no-hardcoded-env-urls // DNS zone name must be this exact string - not a URL
  name: 'privatelink.file.core.windows.net'
  location: 'global'
  tags: tags
}

// 9. Link the DNS zone to the VNet so VMs resolve the private endpoint IP
resource dnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${prefix}-dns-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

// 10. Private Endpoint - puts the storage account on the storage subnet
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${prefix}-storage-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: storageSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-storage-plsc'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['file']
        }
      }
    ]
  }
}

// 11. DNS Zone Group - auto-registers the PE NIC IP in the private DNS zone
resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file-core-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// =============================================================================
// RBAC - Grant 'AVD Users' group SMB access to the FSLogix share
// FSLogix requires 'Storage File Data SMB Share Contributor' on the share scope
// =============================================================================

// Built-in role definition IDs (these are constant across all tenants)
var storageSmbContributorRoleId = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
var storageSmbElevatedContributorRoleId = 'a7264617-510b-434b-a828-9731dc254ea7'

resource fslogixRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, avdUsersGroupId, storageSmbContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageSmbContributorRoleId)
    principalId: avdUsersGroupId
    principalType: 'Group'
  }
}

// Elevated contributor - required for FSLogix to set NTFS permissions on profile directories
resource fslogixElevatedRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, avdUsersGroupId, storageSmbElevatedContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageSmbElevatedContributorRoleId)
    principalId: avdUsersGroupId
    principalType: 'Group'
  }
}

// =============================================================================
// AVD - Host Pool, App Group, Workspace
// =============================================================================

// 12. Host Pool (Pooled, BreadthFirst, with registration token valid 24 h)
var registrationTokenExpiry = dateTimeAdd(baseTime, 'PT24H')

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: '${prefix}-hp'
  location: location
  tags: tags
  properties: {
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    maxSessionLimit: 10
    preferredAppGroupType: 'Desktop'
    startVMOnConnect: true
    registrationInfo: {
      expirationTime: registrationTokenExpiry
      registrationTokenOperation: 'Update'
    }
    // Entra ID join + Intune enrollment flags
    vmTemplate: '{"domain":"","galleryImageOffer":null,"galleryImagePublisher":null,"galleryImageSKU":null,"imageType":"CustomImage","imageUri":null,"customImageId":"${goldenImageId}","namePrefix":"${prefix}-vm","osDiskType":"Premium_LRS","vmSize":{"id":"${vmSize}","cores":4,"ram":16},"galleryItemId":null,"hibernate":false,"diskSizeGB":0,"securityType":"trustedLaunch","secureBoot":true,"vTPM":true}'
  }
}

// 13. Desktop Application Group
resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2023-09-05' = {
  name: '${prefix}-dag'
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    friendlyName: 'AVD Lab Desktop'
  }
}

// 14. Workspace
resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: '${prefix}-ws'
  location: location
  tags: tags
  properties: {
    friendlyName: 'AVD Lab Workspace'
    applicationGroupReferences: [
      appGroup.id
    ]
  }
}

// 15. RBAC - Assign 'Desktop Virtualization User' role to 'AVD Users' group on the App Group
var dvUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

resource avdUsersRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appGroup.id, avdUsersGroupId, dvUserRoleId)
  scope: appGroup
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dvUserRoleId)
    principalId: avdUsersGroupId
    principalType: 'Group'
  }
}

// =============================================================================
// SESSION HOSTS - 2 VMs, Entra ID joined, Intune enrolled, AVD agent installed
// =============================================================================

// Retrieve the host pool registration token (needed by the AVD agent extension)
var hostPoolToken = hostPool.properties.registrationInfo.token

resource sessionHosts 'Microsoft.Compute/virtualMachines@2023-09-01' = [for i in range(0, vmCount): {
  name: '${prefix}-vm-${i}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'    // Required for Entra ID join and Intune enrollment
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        id: goldenImageId     // Your pre-built golden image
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'  // Clean up disk when VM is deleted
      }
    }
    osProfile: {
      computerName: '${prefix}-vm-${i}'
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: false   // Managed via Intune/WUfB
        patchSettings: {
          patchMode: 'Manual'           // AutomaticByPlatform requires a supported marketplace image
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: vmNics[i].id, properties: { deleteOption: 'Delete' } }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    licenseType: 'Windows_Client'   // Enables Azure Hybrid Benefit for W10/W11 multi-session
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}]

// NICs for the session hosts (no public IP - outbound via NAT GW)
resource vmNics 'Microsoft.Network/networkInterfaces@2023-09-01' = [for i in range(0, vmCount): {
  name: '${prefix}-vm-${i}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: avdSubnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}]

// --- Extensions (applied after VM is provisioned) ---

// 16a. Network readiness check - waits for NAT Gateway routes to propagate before Entra join
resource networkReadyExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, vmCount): {
  name: '${prefix}-vm-${i}/NetworkReadyCheck'
  location: location
  tags: tags
  dependsOn: [ sessionHosts, natGateway, vnet ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: '''
        powershell.exe -ExecutionPolicy Unrestricted -Command "
          $maxAttempts = 12
          $attempt = 0
          $connected = $false
          while (-not $connected -and $attempt -lt $maxAttempts) {
            $attempt++
            Write-Output "Connectivity check attempt $attempt of $maxAttempts"
            try {
              $response = Invoke-WebRequest -Uri 'https://login.microsoftonline.com' -UseBasicParsing -TimeoutSec 10
              if ($response.StatusCode -eq 200) {
                $connected = $true
                Write-Output 'Network connectivity confirmed - login.microsoftonline.com reachable'
              }
            } catch {
              Write-Output "Not yet reachable: $_"
              Start-Sleep -Seconds 15
            }
          }
          if (-not $connected) {
            Write-Error 'Network connectivity check failed after all attempts'
            exit 1
          }
        "
      '''
    }
  }
}]

// 16b. AADLoginForWindows - Entra ID join + optional Intune enrollment
resource entraJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, vmCount): {
  name: '${prefix}-vm-${i}/AADLoginForWindows'
  location: location
  tags: tags
  dependsOn: [ networkReadyExtension ]
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
    settings: {}  // No mdmId - Entra join only, Intune enrols automatically via auto-enrolment policy
  }
}]

// 17. AVD Agent (DSC extension registers the VM with the Host Pool)
resource avdAgentExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, vmCount): {
  name: '${prefix}-vm-${i}/Microsoft.PowerShell.DSC'
  location: location
  tags: tags
  dependsOn: [ entraJoinExtension ]
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_09-08-2022.zip'
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: hostPool.name
        registrationInfoTokenCredential: {
          UserName: 'PLACEHOLDER'     // Required field by DSC schema - value is ignored
          Password: 'PrivateSettingsRef:registrationInfoToken'
        }
        aadJoin: true                 // Tells DSC this is an Entra-only join (no AD DS)
      }
    }
    protectedSettings: {
      items: {
        registrationInfoToken: hostPoolToken
      }
    }
  }
}]

// 18. FSLogix configuration via Custom Script Extension
//     Writes the FSLogix registry keys that point to the Azure Files share
resource fslogixConfigExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, vmCount): {
  name: '${prefix}-vm-${i}/FSLogixConfig'
  location: location
  tags: tags
  dependsOn: [ avdAgentExtension ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: '''
        powershell.exe -ExecutionPolicy Unrestricted -Command "
          $RegPath = 'HKLM:\\SOFTWARE\\FSLogix\\Profiles';
          New-Item -Path $RegPath -Force | Out-Null;
          Set-ItemProperty -Path $RegPath -Name Enabled         -Value 1           -Type DWord;
          Set-ItemProperty -Path $RegPath -Name VHDLocations    -Value '\\\\${storageAccount.name}.file.${environment().suffixes.storage}\\fslogix-profiles' -Type MultiString;
          Set-ItemProperty -Path $RegPath -Name VolumeType      -Value 'VHDX'      -Type String;
          Set-ItemProperty -Path $RegPath -Name SizeInMBs       -Value ${fslogixProfileSizeGB * 1024} -Type DWord;
          Set-ItemProperty -Path $RegPath -Name DeleteLocalProfileWhenVHDShouldApply -Value 1 -Type DWord;
          Set-ItemProperty -Path $RegPath -Name FlipFlopProfileDirectoryName -Value 1 -Type DWord;
          Set-ItemProperty -Path $RegPath -Name AccessNetworkAsComputerObject -Value 1 -Type DWord;
          $CloudPath = 'HKLM:\\SOFTWARE\\Policies\\FSLogix\\ODFC';
          New-Item -Path $CloudPath -Force | Out-Null;
          Set-ItemProperty -Path $CloudPath -Name StorageAccountName -Value '${storageAccount.name}' -Type String;
          Write-Output 'FSLogix Entra Kerberos registry keys written successfully.'
        "
      '''
    }
  }
}]

// =============================================================================
// OUTPUTS
// =============================================================================

output vnetId string = vnet.id
output hostSubnetId string = avdSubnetId
output storageSubnetId string = storageSubnetId
output storageAccountName string = storageAccount.name
output fslogixSharePath string = '\\\\${storageAccount.name}.file.${environment().suffixes.storage}\\fslogix-profiles'
output hostPoolName string = hostPool.name
output workspaceName string = workspace.name
output appGroupName string = appGroup.name
