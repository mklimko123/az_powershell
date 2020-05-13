<#

    .SYNOPSIS
    Cmdlet will create a Web App with Connection string to SQL Database.

    .DESCRIPTION
    Function will create logical Azure SQL Server with database and Web App with App Service Plan.
    It will use KeyVault secrets for store SQL admin credentials and referencing them in ARM template during provisioning the logical SQL server.
    App Service Plan are equal to Standard S2. SQL DB are based on DTU service model.

    .EXAMPLE
    Start-Deployment -Environment "Test" -projectNamePrefix "mklimko"

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("Test", "Prod", "Dev")]
    [string]$Environment = "Test",
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[a-zA-Z]{1,10}$")]
    [string]$projectNamePrefix = "mklimko"        
)

$jsonForParameters = ".\parameters.json"
$jsonForDeploy = ".\main.json"
$jsonPath = ".\linked\"
$ArtResGrpName = "ArtifactoryRG" + $Environment
$DeplResGrpName = "DeployRG" + $Environment
$ArtSaName = $("ArtifactorySa" + $Environment); $ArtSaName = $ArtSaName.ToLower()
$ArtSaContainerName = "ArmDeployment"; $ArtSaContainerName = $ArtSaContainerName.ToLower()
$upn = (Get-AzContext).Account.Id
$objectID = (Get-AzADUser -UserPrincipalName $upn).Id
#generate key vault secret
$sqlAdministratorPassword = [System.Web.Security.Membership]::GeneratePassword(30, 10) | ConvertTo-SecureString -AsPlainText -Force
$Location = "eastus"


<# $TenantId = "b41b72d0-4e9f-4c26-8a69-f949f367c91d"
$SubscriptionId = "ecdf3446-334d-454b-a9f3-27f8aa846281"
Connect-AzAccount -TenantId $TenantId  -SubscriptionId $SubscriptionId #>

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

#write parameters from script to parameters.json
$ConvertedJSON = (Get-Content -Path $jsonForParameters) | ConvertFrom-Json
$ConvertedJSON.parameters.modulesUrl.value = $modulesUrl
$ConvertedJSON.parameters.projectNamePrefix.value = $projectNamePrefix
$ConvertedJSON.parameters.objectID.value = $objectID

ConvertTo-Json -InputObject $ConvertedJSON -Depth "4" | Out-File $jsonForParameters -Encoding ascii -Force

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
New-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
    -TemplateFile $jsonForDeploy `
    -SASToken $SAStoken `
    -sqlAdministratorPassword $sqlAdministratorPassword `
    -TemplateParameterFile $jsonForParameters -Verbose