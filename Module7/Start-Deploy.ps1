<#

    .SYNOPSIS
    Cmdlet to deploy VM with Recovery Service Vault.

    .DESCRIPTION
    Function will create VM that is protected by Recovery services vault with policy that preforms daily backups.
    After deployment it will perform a backup of both disks.
    Deployment output will be saved in parameters.json
    
    .EXAMPLE
    Start-Deploy.ps1 -projectNamePrefix "contoso" -Location "eastus"

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("Test", "Prod", "Dev")]
    [string]$Environment = "Test",
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z]{1,10}$")]
    [string]$projectNamePrefix = "contoso",   
    [Parameter(Mandatory = $false)]
    [ValidateSet("eastus", "eastus2", "westus", "westus2", "centralus")]
    [string]$Location = "eastus"
)

$jsonForParameters = ".\parameters.json"
$jsonForDeploy = ".\vmdeploy.json"
$jsonPath = ".\linked\"
$ArtResGrpName = "ArtifactoryRG" + $Environment
$DeplResGrpName = "DeployRG" + $Environment
$ArtSaName = $("ArtifactorySa" + $Environment); $ArtSaName = $ArtSaName.ToLower()
$ArtSaContainerName = "ArmDeployment"; $ArtSaContainerName = $ArtSaContainerName.ToLower()
$AzResourceGroupDeploymentName = "vmdeploy"
$upn = (Get-AzContext).Account.Id
$objectID = (Get-AzADUser -UserPrincipalName $upn).Id
#generate key vault secret
$adminPassword = [System.Web.Security.Membership]::GeneratePassword(30, 10) | ConvertTo-SecureString -AsPlainText -Force

Connect-AzAccount

#create resourse group for Artifactory if not present
if (!(Get-AzResourceGroup -Name $ArtResGrpName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ArtResGrpName -Location $Location -Verbose
}
else {
    Write-Verbose "Resourse Group $ArtResGrpName already exists. Skipping"
}

#create storage account for Artifactory if not present
if (!(Get-AzStorageAccount -ResourceGroupName $ArtResGrpName -Name $ArtSaName -ErrorAction SilentlyContinue)) {
    New-AzStorageAccount -ResourceGroupName $ArtResGrpName -Name $ArtSaName -Location $Location -SkuName Standard_LRS -Kind StorageV2 -Verbose
}
else {
    Write-Verbose "Storage Account $ArtSaName already exists. Skipping"
}

$ArtSaContext = (Get-AzStorageAccount -ResourceGroupName $ArtResGrpName -Name $ArtSaName).Context

#create private blob container for Artifactory if not present
if (!(Get-AzStorageContainer -Name $ArtSaContainerName -Context $ArtSaContext -ErrorAction SilentlyContinue)) {
    New-AzStorageContainer -Name $ArtSaContainerName -Context $ArtSaContext -Permission Off -Verbose
}
else {
    Write-Verbose "Blob Container $ArtSaContainerName already exists. Skipping"
}
 
$modulesUrl = (Get-AzStorageContainer -Name $ArtSaContainerName -Context $ArtSaContext).Context.BlobEndPoint + $ArtSaContainerName
$SAStoken = New-AzStorageContainerSASToken -Name $ArtSaContainerName -Permission r -Context $ArtSaContext | ConvertTo-SecureString -AsPlainText -Force

#create resourse group for deployment if not present
if (!(Get-AzResourceGroup -Name $DeplResGrpName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $DeplResGrpName -Location $Location -Verbose
}
else {
    Write-Verbose "Resource Group $DeplResGrpName already exists. Skipping"
}

#get arm templates
$JsonFiles = Get-ChildItem -Path $jsonPath -Recurse -Include *.json

#upload arm templates to blob storage
foreach ($File in $JsonFiles) {
    Set-AzStorageBlobContent -File $File.FullName -Container $ArtSaContainerName -Blob $File.Name -Context $ArtSaContext -Force -Verbose
}

#start deployment
try {
    New-AzResourceGroupDeployment -Name $AzResourceGroupDeploymentName -ResourceGroupName $DeplResGrpName -TemplateFile $jsonForDeploy `
        -SASToken $SAStoken `
        -adminPassword $adminPassword `
        -modulesUrl $modulesUrl `
        -objectID $objectID `
        -projectNamePrefix $projectNamePrefix -Verbose -ErrorAction Stop
}
catch {
    Write-Verbose "AzResourceGroupDeployment failed. Exiting..."
    throw $_
}

Write-Verbose "Deployment completed. Saving outputs to $jsonForParameters"

#get outputs from deployment
$deployments = Get-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName -DeploymentName $AzResourceGroupDeploymentName
$RecoveryVaultName = $deployments.Outputs.recoveryVaultName.value
$targetVmName = $deployments.Outputs.vmName.value
$targetVmSize = $deployments.Outputs.vmSize.value
$targetNSGid = $deployments.Outputs.nsgID.value
$targetNicName = $deployments.Outputs.nicName.value
$targetSubnetID = $deployments.Outputs.subnetID.value
$targetPubIPname = $deployments.Outputs.pubIpName.value 
$targetLocation = $deployments.Outputs.location.value 

#save outputs from deployment to json
$ConvertedJSON = (Get-Content -Path $jsonForParameters) | ConvertFrom-Json
$ConvertedJSON.parameters.vmName.value = $targetVmName
$ConvertedJSON.parameters.nicName.value = $targetNicName
$ConvertedJSON.parameters.pubIPname.value = $targetPubIPname
$ConvertedJSON.parameters.nsgID.value = $targetNSGid
$ConvertedJSON.parameters.subnetID.value = $targetSubnetID
$ConvertedJSON.parameters.vmLocation.value = $targetLocation
$ConvertedJSON.parameters.vmSize.value = $targetVmSize
$ConvertedJSON.parameters.recoveryVaultName.value = $RecoveryVaultName

ConvertTo-Json -InputObject $ConvertedJSON -Depth "4" | Out-File $jsonForParameters -Encoding ascii -Force

#configure recovery vault
Write-Verbose "Configuring $RecoveryVaultName Recovery Vault"

$targetVault = Get-AzRecoveryServicesVault -ResourceGroupName $DeplResGrpName -Name $RecoveryVaultName
$targetVaultID = Get-AzRecoveryServicesVault -ResourceGroupName $DeplResGrpName -Name $RecoveryVaultName | Select-Object -ExpandProperty ID
Set-AzRecoveryServicesBackupProperty -Vault $targetVault -BackupStorageRedundancy LocallyRedundant -Verbose
Set-AzRecoveryServicesVaultProperty -VaultId $targetVault.ID -SoftDeleteFeatureState Disable -Verbose

Write-Verbose "Starting backup job for $targetVmName."

#start backup job for target VM
$backupContainer = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -Status Registered -FriendlyName $targetVmName -VaultId $targetVaultID
$backupItem = Get-AzRecoveryServicesBackupItem -Container $backupContainer -WorkloadType AzureVM -VaultId $targetVaultID
$backupJob = Backup-AzRecoveryServicesBackupItem -Item $backupItem -VaultId $targetVaultID -Verbose

Wait-AzRecoveryServicesBackupJob -Job $backupJob -VaultId $targetVaultID -Timeout 3600

Write-Verbose "Backup job for $targetVmName completed."