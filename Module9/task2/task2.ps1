<#

    .SYNOPSIS
    Cmdlet to create two VMs, Automation Account with dscConfiguration.

    .DESCRIPTION
    Function will compile the DSC configuration, onboard VMs, assign different DSC nodes configurations to VMs via linked ARM templates.

    .EXAMPLE
    task2.ps1 -Location "eastus" -Environment "Test" -projectPrefix "mod9t2"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("eastus", "eastus2", "westus", "westus2", "centralus")]
    [string]$Location = "eastus",
    [Parameter(Mandatory = $false)]
    [ValidateSet("Test", "Prod", "Dev")]
    [string]$Environment = "Test",              
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z0-9]{1,10}$")]
    [string]$projectPrefix = "mod9t2",
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3)]
    [string]$vmCount = 2
)
add-type -AssemblyName System.Web

$DeplResGrpName = "DeployRG" + $Environment
$ArtResGrpName = "ArtifactoryRG" + $Environment
$ArtSaName = "ArtifactorySa" + $Environment; $ArtSaName = $ArtSaName.ToLower()
$ArtSaContainerName = "ArtifactoryContainer" + $projectPrefix; $ArtSaContainerName = $ArtSaContainerName.ToLower()
$jsonForDeploy = ".\main.json"
$jsonForParameters = ".\parameters.json"
$artifactsPath = ".\linked\"

$vmNames = @()
$secrets = @()
#generate key vault secrets
for ($i = 0; $i -lt $vmCount; $i++) {
    $vmNames += $projectPrefix + "Vm" + $i
    $secretName = $vmNames[$i] + "adm"
    $secretValue = [System.Web.Security.Membership]::GeneratePassword(30, 10)
    $secrets += @{ secretName = $secretName; secretValue = $secretValue }
}
$keyVaultSecrets = @{ "secrets" = $secrets }

#connect to azure
try {
    $TenantId = "aab3f9ba-143d-45b6-aa7c-d76e5a81e83f"
    $SubscriptionId = "5e8c7769-1a7c-4a26-93d0-1551609e275e"
    Connect-AzAccount -TenantId $TenantId  -SubscriptionId $SubscriptionId
}
catch {
    throw "Failed to connect to Azure Portal. Exiting"
}

$objectId = (Get-AzADUser).Id

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

#create private container for Artifactory if not present
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
    $ConvertedJSON.parameters.vmNames.value = $vmNames

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
$artfactsFiles = Get-ChildItem -Path $artifactsPath -Recurse -Include *.json, *.ps1, *.nupkg

#upload arm templates to blob storage
foreach ($File in $artfactsFiles) {
    Set-AzStorageBlobContent -File $File.FullName -Container $ArtSaContainerName -Blob $File.Name -Context $ArtSaContext -Force -Verbose
}

#start deployment
New-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
    -TemplateFile $jsonForDeploy `
    -TemplateParameterFile $jsonForParameters `
    -artifactsLocationSasToken $artifactsLocationSasToken `
    -keyVaultSecrets $keyVaultSecrets `
    -Verbose
    
<# Test-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
    -TemplateFile $jsonForDeploy `
    -TemplateParameterFile $jsonForParameters `
    -artifactsLocationSasToken $artifactsLocationSasToken `
    -keyVaultSecrets $keyVaultSecrets `
    -Verbose #>