<#

    .SYNOPSIS
    Cmdlet to restore VM with unmanaged disks.

    .DESCRIPTION
    Function will restore VM from Recovery services vault using unmanaged disks.
    Deployment output from Start-Deploy.ps1 in parameters.json will be used to restore VM in original NSG, VNet and subnet.

    .EXAMPLE
    Start-Restore.ps1 -restorePrefix "restored"

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("Test", "Prod", "Dev")]
    [string]$Environment = "Test",
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z-]{1,10}$")]
    [string]$restorePrefix = "restored-"
)
$jsonForParameters = ".\parameters.json"
$jsonForRestore = ".\vmrestore.json"
$DeplResGrpName = "DeployRG" + $Environment
$RecoverySaName = "RecoverySa" + $Environment; $RecoverySaName = $RecoverySaName.ToLower()

#get required parameters from VM deployment output 
try {
    $ConvertedJSON = (Get-Content -Path $jsonForParameters) | ConvertFrom-Json
}
catch {
    Write-Verbose "Failed to retrieve data from $jsonForParameters. Exiting"
    throw $_
}

$RecoveryVaultName = $ConvertedJSON.parameters.recoveryVaultName.value
$targetLocation = $ConvertedJSON.parameters.vmLocation.value
$targetVmName = $ConvertedJSON.parameters.vmName.value

Connect-AzAccount

#get Recovery Vault 
$targetVault = Get-AzRecoveryServicesVault -ResourceGroupName $DeplResGrpName -Name $RecoveryVaultName
$targetVaultID = Get-AzRecoveryServicesVault -ResourceGroupName $DeplResGrpName -Name $RecoveryVaultName | Select-Object -ExpandProperty ID

#create storage account for restored VM data
if (!(Get-AzStorageAccount -ResourceGroupName $DeplResGrpName -Name $RecoverySaName -ErrorAction SilentlyContinue)) {
    New-AzStorageAccount -ResourceGroupName $DeplResGrpName -Name $RecoverySaName -Location $targetLocation -SkuName Standard_LRS -Kind StorageV2 -Verbose
}
else {
    Write-Verbose "Storage Account $RecoverySaName already exists. Skipping"
}


$startDate = (Get-Date).AddDays(-1)
$endDate = Get-Date

#get backup for target VM
$backupContainer = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -Status Registered -FriendlyName $targetVmName -VaultId $targetVaultID
$backupItem = Get-AzRecoveryServicesBackupItem -Container $backupContainer -WorkloadType AzureVM -VaultId $targetVaultID

Write-Verbose "Starting restore job for $targetVmName."

#start backup job for targe VM (first available restore point used)
$restorePoint = Get-AzRecoveryServicesBackupRecoveryPoint -Item $backupItem -StartDate $startDate.ToUniversalTime() -EndDate $endDate.ToUniversalTime() -VaultId $targetVaultID -Verbose
$restoreJob = Restore-AzRecoveryServicesBackupItem -RecoveryPoint $restorePoint[0] -StorageAccountName $RecoverySaName -StorageAccountResourceGroupName $DeplResGrpName -VaultId $targetVaultID -VaultLocation $targetVault.Location -Verbose

Wait-AzRecoveryServicesBackupJob -Job $restoreJob -VaultId $targetVaultID -Timeout 3600 -Verbose 

#get restore job details content
$restoreJob = Get-AzRecoveryServicesBackupJob -Job $restoreJob -VaultId $targetVaultID
if ($restoreJob.Status -ne "Completed") {
    throw "Restore job for $targetVmName failed. Exiting"
}
Write-Verbose "Restore job for $targetVmName completed."
$restoreDetails = Get-AzRecoveryServicesBackupJobDetails -Job $restoreJob -VaultId $targetVaultID

$properties = $restoreDetails.properties
$storageAccountName = $properties["Target Storage Account Name"]
$templateBlobURI = $properties["Template Blob Uri"]
$containerName = $properties["Config Blob Container Name"]
$templateName = $templateBlobURI.Split('/')[-1]

#complete url to template with SAS token to access template content
Set-AzCurrentStorageAccount -Name $storageAccountName -ResourceGroupName $DeplResGrpName | Out-Null
$templateBlobFullURI = New-AzStorageBlobSASToken -Container $containerName -Blob $templateName -Permission r -FullUri

#extract data and os disk information from template
try {
    $InvokeRestMethod = Invoke-RestMethod -Uri $templateBlobFullURI
}
catch {
    Write-Verbose "Failed to retreive data from $templateBlobFullURI. Exiting"
    throw $_
}

$context = (Get-AzStorageAccount -ResourceGroupName $DeplResGrpName -Name $storageAccountName).Context.BlobEndPoint
$dataDisks = @()
foreach ($item in $InvokeRestMethod.resources) {
    if ($item.type -eq "Microsoft.Compute/virtualMachines") {
        foreach ($disk in $item.properties.storageProfile.dataDisks) {
            $dataDiskURI = $context + $containerName + "/" + $($disk.name + ".vhd")
            $dataDisks += @{ name = $($disk.name + ".vhd"); uri = $dataDiskURI }
        }
        $osDiskName = $($item.properties.storageProfile.osDisk[0].name + ".vhd")
        $osDiskURI = $context + $containerName + "/" + $osDiskName
    }    
}

#write retreived parameters to parameters.json for next deployment
$ConvertedJSON.parameters.dataDisks.value = $dataDisks
$ConvertedJSON.parameters.osDiskName.value = $osDiskName
$ConvertedJSON.parameters.osDiskURI.value = $osDiskURI

ConvertTo-Json -InputObject $ConvertedJSON -Depth "4" | Out-File $jsonForParameters -Encoding ascii -Force

#start deployment
New-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName -TemplateFile $jsonForRestore -restorePrefix $restorePrefix -TemplateParameterFile $jsonForParameters -Verbose