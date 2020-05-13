[CmdletBinding()]
param ()

$DeplResGrpName = "DeployRGTest"
$ArtResGrpName = "ArtifactoryRGTest"
$ArtSaName = "ArtifactorySaTest"; $ArtSaName = $ArtSaName.ToLower()
$ArtSaContainerName = "ArmDeployment"; $ArtSaContainerName = $ArtSaContainerName.ToLower()
$Location = "eastus2"
$jsonForDeploy = ".\arm\main.json"
$jsonPath = ".\arm\linked\"

az login

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

#create azure SP
$ServicePrincipal = az ad sp create-for-rbac --skip-assignment --name myAKSClusterSP | ConvertFrom-Json
$servicePrincipalClientId = $ServicePrincipal.appId | ConvertTo-SecureString -AsPlainText -Force
$servicePrincipalSecret = $ServicePrincipal.password | ConvertTo-SecureString -AsPlainText -Force

Start-Sleep -Seconds 60

#start deployment
New-AzResourceGroupDeployment -ResourceGroupName $DeplResGrpName `
    -TemplateFile $jsonForDeploy `
    -SASToken $SAStoken `
    -modulesUrl $modulesUrl `
    -servicePrincipalClientId $servicePrincipalClientId `
    -servicePrincipalClientSecret $servicePrincipalSecret `
    -Verbose