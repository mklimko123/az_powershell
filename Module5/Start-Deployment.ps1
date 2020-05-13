<#

    .SYNOPSIS
    Cmdlet to deploy two App Service Plans, App Services, one Traffic manager with two endpoints.

    .DESCRIPTION
    Function will create Azure App Service Plans with Azure App Services under two specified locations. 
    Function will build hight available load balancer infrastructure based on Azure Traffic Manager DNS load balancer solution.

    .EXAMPLE
    Start-Deployment -Locations eastus,westus -Environment Prod

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [Alias("Locations")]
    [ValidateSet("eastus", "eastus2", "westus", "westus2", "centralus")]
    [ValidateCount(2,2)]
    [string[]]$AppServiceLocation = @("eastus","centralus"),
    [Parameter(Mandatory = $false)]
    [ValidateSet("Test", "Prod", "Dev")]
    [string]$Environment = "Test"    
)

$jsonForParameters = ".\parameters.json"
$jsonForDeploy = ".\main.json"
$jsonPath = ".\linked\"
$ArtResGrpName = "Artifactory" + $Environment
$DeplResGrpName = "Deploy" + $Environment
$ArtSaName = $("ArtSa" + $Environment); $ArtSaName = $ArtSaName.ToLower()
$ArtSaContainerName = "ArmDeployment"; $ArtSaContainerName = $ArtSaContainerName.ToLower()

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

#write parameters from script to parameters.json
$ConvertedJSON = (Get-Content -Path $jsonForParameters) | ConvertFrom-Json
$ConvertedJSON.parameters.modulesUrl.value = $modulesUrl
$ConvertedJSON.parameters.AppServiceLocations.value = $AppServiceLocation

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
try {
    New-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
        -TemplateFile $jsonForDeploy `
        -SASToken $SAStoken `
        -TemplateParameterFile $jsonForParameters  -Verbose -ErrorAction Stop
}
catch {
    Write-Host "AzResourceGroupDeployment failed. Starting debug" -ForegroundColor Red -BackgroundColor Black
    #test deployment
    Test-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
        -TemplateFile $jsonForDeploy `
        -SASToken $SAStoken `
        -TemplateParameterFile $jsonForParameters  -Verbose -Debug -SkipTemplateParameterPrompt -ErrorAction Stop
    throw $_
}