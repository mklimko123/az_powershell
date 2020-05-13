<#

    .SYNOPSIS
    Cmdlet to create VM with Automation Account.

    .DESCRIPTION
    AA contains PowerShell Workflow runbook. Job will stop all VMs under subscription. Job will be triggered after VM deployment.
    KeyVault secret will be created and used to pass admin credentials to VM.
    App registration named "vmContributorServicePrincipal" with VM contributor role will be created before ARM deployment. 

    .EXAMPLE
    task1.ps1 -Location "eastus" -Environment "Test" -projectPrefix "mod9t1"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("eastus", "eastus2", "westus", "westus2", "centralus")]
    [string]$Location = "eastus2",
    [Parameter(Mandatory = $false)]
    [ValidateSet("Test", "Prod", "Dev")]
    [string]$Environment = "Test",              
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z0-9]{1,10}$")]
    [string]$projectPrefix = "mod9t1",
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z0-9-]{1,50}$")]
    [string]$ServicePrincipalName = "vmContributorServicePrincipal"
)
add-type -AssemblyName System.Web

$DeplResGrpName = "DeployRG2" + $Environment
$ArtResGrpName = "ArtifactoryRG2" + $Environment
$ArtSaName = "ArtifactorySa2" + $Environment; $ArtSaName = $ArtSaName.ToLower()
$ArtSaContainerName = "ArtifactoryContainer" + $projectPrefix; $ArtSaContainerName = $ArtSaContainerName.ToLower()
$jsonForDeploy = ".\main.json"
$jsonForParameters = ".\parameters.json"
$artifactsPath = ".\linked\"
$secretName = "vmAdministrator"
$ServicePrincipalName = "vmContributorServicePrincipal"
#generate key vault secret
$secretValue = [System.Web.Security.Membership]::GeneratePassword(30, 10) | ConvertTo-SecureString -AsPlainText -Force

try {
    $TenantId = "aab3f9ba-143d-45b6-aa7c-d76e5a81e83f"
    $SubscriptionId = "5e8c7769-1a7c-4a26-93d0-1551609e275e"
    Connect-AzAccount -TenantId $TenantId  -SubscriptionId $SubscriptionId
}
catch {
    throw "Failed to connect to Azure Portal. Exiting"
}

$Scope = "/subscriptions/" + $SubscriptionId

$objectId = (Get-AzADUser).Id

#create resourse group for Artifactory if not present
if (!(Get-AzResourceGroup -Name $ArtResGrpName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ArtResGrpName -Location $Location -Verbose
}
else {
    Write-Verbose "Resourse Group $ArtResGrpName already exists. Skipping"
}

#create SP with VM contributor role if not exists, overwise recreate SP
if (!(Get-AzADServicePrincipal -DisplayName $ServicePrincipalName)) {
    $ServicePrincipal = New-AzADServicePrincipal -DisplayName $ServicePrincipalName  -Role "Virtual Machine Contributor"
    Start-Sleep -Seconds 30
    New-AzRoleAssignment -RoleDefinitionName "Reader" -ApplicationId $ServicePrincipal.ApplicationId -Scope $Scope -Verbose
    $vmContibutorServicePrincipal = @{ AppId = $ServicePrincipal.ApplicationId; Secret = $ServicePrincipal.Secret }
}
else {
    Remove-AzADApplication -ApplicationId ((Get-AzADServicePrincipal -DisplayName $ServicePrincipalName).ApplicationId)
    $ServicePrincipal = New-AzADServicePrincipal -DisplayName $ServicePrincipalName  -Role "Virtual Machine Contributor"
    Start-Sleep -Seconds 30
    New-AzRoleAssignment -RoleDefinitionName "Reader" -ApplicationId $ServicePrincipal.ApplicationId -Scope $Scope -Verbose
    $vmContibutorServicePrincipal = @{ AppId = $ServicePrincipal.ApplicationId; Secret = $ServicePrincipal.Secret }
}

#create storage account for Artifactory if not present
if (!(Get-AzStorageAccount -ResourceGroupName $ArtResGrpName -Name $ArtSaName -ErrorAction SilentlyContinue)) {
    New-AzStorageAccount -ResourceGroupName $ArtResGrpName -Name $ArtSaName -Location $Location -SkuName Standard_LRS -Kind StorageV2 -Verbose
}
else {
    Write-Verbose "Storage Account $ArtSaName already exists. Skipping"
}

$ArtSaContext = (Get-AzStorageAccount -ResourceGroupName $ArtResGrpName -Name $ArtSaName).Context

if (!(Get-AzStorageContainer -Name $ArtSaContainerName -Context $ArtSaContext -ErrorAction SilentlyContinue)) {
    New-AzStorageContainer -Name $ArtSaContainerName -Context $ArtSaContext -Permission Off -Verbose
}
else {
    Write-Verbose "Blob Container $ArtSaContainerName already exists. Skipping"
}

$artifactsLocation = (Get-AzStorageContainer -Name $ArtSaContainerName -Context $ArtSaContext).Context.BlobEndPoint + $ArtSaContainerName
$artifactsLocationSasToken = New-AzStorageContainerSASToken -Name $ArtSaContainerName -Permission r -Context $ArtSaContext | ConvertTo-SecureString -AsPlainText -Force

#write parameters from script to parameters.json
try {
    $ConvertedJSON = (Get-Content -Path $jsonForParameters) | ConvertFrom-Json

    $ConvertedJSON.parameters.artifactsLocation.value = $artifactsLocation
    $ConvertedJSON.parameters.objectId.value = $objectId
    $ConvertedJSON.parameters.projectPrefix.value = $projectPrefix
    $ConvertedJSON.parameters.secretName.value = $secretName

    ConvertTo-Json -InputObject $ConvertedJSON -Depth "4" | Out-File $jsonForParameters -Encoding ascii -Force

}
catch {
    throw "Failed to retrieve data from $jsonForParameters"
}

#create resourse group for deployment if not present
if (!(Get-AzResourceGroup -Name $DeplResGrpName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $DeplResGrpName -Location $Location -Verbose
}
else {
    Write-Verbose "Resource Group $DeplResGrpName already exists. Skipping"
}

#get arm templates
$JsonFiles = Get-ChildItem -Path $artifactsPath -Recurse -Include *.json, *.ps1

#upload arm templates to blob storage
foreach ($File in $JsonFiles) {
    Set-AzStorageBlobContent -File $File.FullName -Container $ArtSaContainerName -Blob $File.Name -Context $ArtSaContext -Force -Verbose
}

#start deployment
New-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
    -TemplateFile $jsonForDeploy `
    -TemplateParameterFile $jsonForParameters `
    -artifactsLocationSasToken $artifactsLocationSasToken `
    -vmContibutorServicePrincipal $vmContibutorServicePrincipal `
    -secretValue $secretValue `
    -Verbose

<# Test-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
    -TemplateFile $jsonForDeploy `
    -TemplateParameterFile $jsonForParameters `
    -artifactsLocationSasToken $artifactsLocationSasToken `
    -vmContibutorServicePrincipal $vmContibutorServicePrincipal `
    -secretValue $secretValue `
    -Verbose #>