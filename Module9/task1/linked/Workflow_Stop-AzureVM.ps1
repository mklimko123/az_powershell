workflow Shutdown-ARM-VMs-Parallel
{

	$SubscriptionId         = Get-AutomationVariable -Name  "SubscriptionId"
	$TenantID               = Get-AutomationVariable -Name  "TenantID"
	$CredentialAssetName    = Get-AutomationVariable -Name  "CredentialName"
   
	"CredentialAssetName: $CredentialAssetName"
	#Get the credential with the above name from the Automation Asset store
	$Cred = Get-AutomationPSCredential -Name $CredentialAssetName
	if(!$Cred) {
        Throw "Could not find an Automation Credential Asset named '${CredentialAssetName}'. Make sure you have created one in this Automation Account."
    }

    #Connect to your Azure Account
	$Account = Login-AzureRmAccount -Credential $Cred -TenantId $TenantID -ServicePrincipal 
    
	$subscription = Get-AzureRmSubscription | Where-Object {$_.Id -eq $SubscriptionId} | Set-AzureRmContext

	$vms = Get-AzureRmVM
		
	Foreach -Parallel ($vm in $vms){
	    Write-Output "Stopping $($vm.Name)"
	    Stop-AzureRmVm -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Force
	}
}