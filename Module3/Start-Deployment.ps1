<#

    .SYNOPSIS
    Cmdlet to deploy Storage Account and VNet

    .DESCRIPTION
    Function will create Storage Account and VNet in specified location. 
    JSON templates for SA and VNet are provided in \linked directory.
    Parameters for resources are set in parameters.json file.
    Default parameters for cmdlet are:  Location="East US 2"
                                        ProjectNamePrefix="mklimko"
                                        StorageNamePrefix="mklimko"
    .EXAMPLE
    Start-Deployment -Location "East US 2" -ProjectNamePrefix "mklimko" -StorageNamePrefix "mklimko" -Verbose

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateSet("eastus", "eastus2","westus","westus2","centralus")]
    [string]$location = "eastus2", 
    [Parameter(Mandatory = $false, Position = 1)]
    [ValidatePattern("^[a-zA-Z0-9-]{1,10}$")]
    [string]$projectNamePrefix = "mklimko", #prefix to generate names for resource group
    [Parameter(Mandatory = $false, Position = 2)]
    [ValidatePattern("^[a-z0-9]{1,10}$")]
    [string]$storageNamePrefix = "mklimko" #prefix to generate names for storage account
)

$jsonForParameters = ".\parameters.json"
$jsonForDeploy = ".\main.json"
$jsonTemplatesPath = ".\linked\"
$templatesResGrpName = $projectNamePrefix + "_templatesRG"
$deployResGrpName = $projectNamePrefix + "_deployRG"
$storageAccountName = $projectNamePrefix + "artifactory"
$containerName = "armtemplates"

Connect-AzAccount
    
#create resourse group for arm templates if not present
if (!(Get-AzResourceGroup -Name $templatesResGrpName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $templatesResGrpName -Location $location -Verbose
}
else {
    Write-Verbose "Resourse Group $templatesResGrpName already exists. Skipping"
}

#create storage account for arm templates if not present
if (!(Get-AzStorageAccount -ResourceGroupName $templatesResGrpName -Name $storageAccountName -ErrorAction SilentlyContinue)) {
    New-AzStorageAccount -ResourceGroupName $templatesResGrpName -Name $storageAccountName -Location $location -SkuName Standard_LRS -Kind StorageV2 -Verbose
}
else {
    Write-Verbose "Storage Account $storageAccountName already exists. Skipping"
}
$storageAccount = Get-AzStorageAccount -ResourceGroupName $templatesResGrpName -Name $storageAccountName    
$context = $storageAccount.Context

#create blob container for arm templates if not present
if (!(Get-AzStorageContainer -Name $containerName -Context $context -ErrorAction SilentlyContinue)) {
    New-AzStorageContainer -Name $containerName -Context $context -Permission Off -Verbose
}
else {
    Write-Verbose "Blob Container $containerName already exists. Skipping"
}

$templatesUri = (Get-AzStorageContainer -Name $containerName -Context $context).Context.BlobEndPoint + $containerName
$SAStoken = New-AzStorageContainerSASToken -Name $containerName -Permission r -Context $context

#create resourse group for deployment if not present
if (!(Get-AzResourceGroup -Name $deployResGrpName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $deployResGrpName -Location $location -Verbose
}
else {
    Write-Verbose "Resource Group $deployResGrpName already exists. Skipping"
}

#get arm templates
$JsonFiles = Get-ChildItem -Path $jsonTemplatesPath -Recurse -Include *.json

#upload arm templates to blob storage
foreach ($File in $JsonFiles) {
    Set-AzStorageBlobContent -File $File.FullName -Container $containerName -Blob $File.Name -Context $context -Force -Verbose
}

#start deployment
try {
    New-AzResourceGroupDeployment -ResourceGroupName $deployResGrpName -TemplateFile $jsonForDeploy -templatesUri $templatesUri -storagePrefix $storageNamePrefix `
        -SASToken $SAStoken -TemplateParameterFile $jsonForParameters  -Verbose -ErrorAction Stop
}
catch {
    Write-Host "AzResourceGroupDeployment failed. Starting debug" -ForegroundColor Red -BackgroundColor Black
    #test deployment
    Test-AzResourceGroupDeployment -ResourceGroupName $deployResGrpName -TemplateFile $jsonForDeploy -templatesUri $templatesUri -storagePrefix $storageNamePrefix `
        -SASToken $SAStoken -TemplateParameterFile $jsonForParameters -Verbose -Debug
    throw $_
}