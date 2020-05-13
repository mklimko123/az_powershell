<#

    .SYNOPSIS
    Cmdlet to deploy Storage Account, Virtual Machine with DSC extension, VNet, Public IP with DNS label, Network Interface, Network Security Group, Key Vault

    .DESCRIPTION
    Function will create Virtual Machine (Windows) and configure IIS using a DSC Extension. 
    It will configure Network Security Group (NSG) to be able to access custom IIS web site through the Internet on port 8080. 
    KeyVault will be used with secrets for store VM admin credentials and referencing them in ARM template during provisioning the VM.

    .EXAMPLE
    Start-Deployment -Location "eastus2" -Environment "Dev" -vmAdmName "localadmin" -Verbose

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("eastus", "eastus2", "westus", "westus2", "centralus")]
    [string]$Location = "eastus2",
    [Parameter(Mandatory = $false)]
    [ValidateSet("Test", "Prod", "Dev")]
    [string]$Environment = "Test",              
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z0-9]{1,10}$")]
    [string]$storagePrefix = "mklimko", #prefix to generate name for SA
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z0-9]{1,10}$")]
    [string]$vnetPrefix = "mklimko", #prefix to generate name for VNet
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z0-9]{1,10}$")]
    [string]$vmPrefix = "mklimko", #prefix to generate name for VM
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z0-9]{1,10}$")]
    [string]$dnsPrefix = "mklimko", #DNS prefix for VM
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z]{1,10}$")]
    [string]$vmAdmName = "vmLocalAdmin" #UPN for local administrator on VM
)

$jsonForParameters = ".\parameters.json"
$jsonForDeploy = ".\main.json"
$jsonPath = ".\linked\"
$ArtResGrpName = "Artifactory" + $Environment
$DeplResGrpName = "Deploy" + $Environment
$ArtSaName = $("ArtSa" + $Environment); $ArtSaName = $ArtSaName.ToLower()
$ArtSaContainerName = "ArmDeployment"; $ArtSaContainerName = $ArtSaContainerName.ToLower()
$KeyVaultName = "DeployKetVault-" + $Environment
$upn = (Get-AzContext).Account.Id
$objectID = (Get-AzADUser -UserPrincipalName $upn).Id
$secretName = "vmAdminPassword"
#generate key vault secret
$secretValue = [System.Web.Security.Membership]::GeneratePassword(30, 10) | ConvertTo-SecureString -AsPlainText -Force

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

#pack dsc configuration and required modules to blob storage
Publish-AzVMDscConfiguration -ConfigurationPath "$($jsonPath)IISWebsite.ps1" -AdditionalPath @("$($jsonPath)xWebAdministration", "$($jsonPath)xNetworking") `
    -ResourceGroupName $ArtResGrpName -StorageAccountName $ArtSaName -ContainerName $ArtSaContainerName -Verbose -Force
 
$modulesUrl = (Get-AzStorageContainer -Name $ArtSaContainerName -Context $ArtSaContext).Context.BlobEndPoint + $ArtSaContainerName
$SAStoken = New-AzStorageContainerSASToken -Name $ArtSaContainerName -Permission r -Context $ArtSaContext | ConvertTo-SecureString -AsPlainText -Force

#write parameters from script to parameters.json
$ConvertedJSON = (Get-Content -Path $jsonForParameters) | ConvertFrom-Json
$ConvertedJSON.parameters.modulesUrl.value = $modulesUrl
$ConvertedJSON.parameters.KeyVaultName.value = $keyVaultName
$ConvertedJSON.parameters.objectID.value = $objectID
$ConvertedJSON.parameters.secretName.value = $secretName
$ConvertedJSON.parameters.storagePrefix.value = $storagePrefix
$ConvertedJSON.parameters.vnetPrefix.value = $vnetPrefix
$ConvertedJSON.parameters.vmPrefix.value = $vmPrefix
$ConvertedJSON.parameters.vmAdminLogin.value = $vmAdmName
$ConvertedJSON.parameters.dnsPrefix.value = $dnsPrefix

ConvertTo-Json -InputObject $ConvertedJSON -Depth "5" | Out-File $jsonForParameters -Encoding ascii -Force

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
    New-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
        -TemplateFile $jsonForDeploy `
        -modulesUrl $modulesUrl `
        -SASToken $SAStoken `
        -secretValue $secretValue `
        -TemplateParameterFile $jsonForParameters  -Verbose -ErrorAction Stop
}
catch {
    Write-Host "AzResourceGroupDeployment failed. Starting debug" -ForegroundColor Red -BackgroundColor Black
    #test deployment
    Test-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
        -TemplateFile $jsonForDeploy `
        -modulesUrl $modulesUrl `
        -SASToken $SAStoken `
        -secretValue $secretValue `
        -TemplateParameterFile $jsonForParameters  -Verbose -Debug -SkipTemplateParameterPrompt -ErrorAction Stop
    throw $_
}