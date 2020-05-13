Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

Connect-AzAccount

$script:Location = "East US 2"
function Set-AzVNetCreation {
    <#

    .SYNOPSIS
    Cmdlet to create multiple VNets and Subnets.

    .DESCRIPTION
    Function allows you to specify number of VNets and subnets per VNet. All resources will be created in East US 2 location.
    Default parameter values are:   VNetCount = 2  (range from 1 to 5)
                                    SubnetCount = 2 (range from 1 to 5)

    .EXAMPLE
    Set-AzVNetCreation -VNetCount 3 -SubnetCountPerVNet 1 -Verbose

    #>

    [CmdletBinding()]
    param (
        [Parameter (Mandatory = $false, Position = 0)]
        [ValidateRange(1, 5)]
        [int]$VNetCount = 2,
        [Parameter (Mandatory = $false, Position = 1)]
        [ValidateRange(1, 5)]
        [int]$SubnetCountPerVNet = 2
    )    

    for ($i = 1; $i -le $VNetCount; $i++) {
        $RG = "Resource_Group$($i)"
        $VNetName = "VNet$($i)"
        $VNetPrefix = "10.$($i)0.0.0/16"
        $GWSubPrefix = "10.$($i)0.255.0/27"
        $GWIPName = "VNet$($i)_GW_IP"
        $GWIPConfigName = "Gw$($i)IpConfig"
        $GWName = "VNet$($i)_GW"

        #create resource group
        try {
            New-AzResourceGroup -Name $RG -Location $Location -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Warning "Failed to create Resourse Group. Exiting..."
            throw $_
        }
        Write-Verbose "$RG is created"

        #create virtual network    
        $VNet = New-AzVirtualNetwork -ResourceGroupName $RG -Location $Location -Name $VNetName -AddressPrefix $VNetPrefix
        Write-Verbose "$VNetName is created"

        for ($j = 1; $j -le $SubnetCountPerVNet; $j++) {
            $SubName = "Subnet$($j)"
            $SubPrefix = "10.$($i)0.$($j).0/24"
            #create subnet config    
            Add-AzVirtualNetworkSubnetConfig -Name $SubName -AddressPrefix $SubPrefix -VirtualNetwork $VNet | Out-Null
            Write-Verbose "Subnet $SubPrefix is created"
            $VNet | Set-AzVirtualNetwork | Out-Null
        }   

        #add gateway subnet
        $VNet = Get-AzVirtualNetwork -ResourceGroupName $RG -Name $VNetName
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $GWSubPrefix -VirtualNetwork $VNet | Out-Null
        Write-Verbose "Gateway subnet $GWSubPrefix is created" 
        $VNet | Set-AzVirtualNetwork | Out-Null

        #set public ip for gateway
        $GwPublicIP = New-AzPublicIpAddress -Name $GWIPName -ResourceGroupName $RG -Location $Location -AllocationMethod Dynamic
        Write-Verbose "Public IP for $GWIPName is created" 

        #set gateway configuration    
        $VNet = Get-AzVirtualNetwork -ResourceGroupName $RG -Name $VNetName
        $GwSubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $VNet
        $GwIpConfig = New-AzVirtualNetworkGatewayIpConfig -Name $GWIPConfigName -SubnetId $GwSubnet.Id -PublicIpAddressId $GwPublicIp.Id
        Write-Verbose "Gateway configuration for $GWIPName is created"

        #create virtual network gateway    
        New-AzVirtualNetworkGateway -Name $GWName -ResourceGroupName $RG -Location $Location `
            -IpConfigurations $GwIpConfig -GatewayType Vpn -VpnType RouteBased -GatewaySku Basic -AsJob | Out-Null  
    }
    
    Write-Verbose "Waiting for VirtualNetworkGateway creation to complete..."
    Get-Job | Where-Object { $_.State -eq 'Running' } | Wait-Job | Out-Null
    Write-Verbose "VirtualNetworkGateway creation completed"
}

function Set-AzVNetConnection {
    <#

    .SYNOPSIS
    Cmdlet to create VNet-to-VNet connection between two VNets.

    .DESCRIPTION
    Function creates connection between any two VNets.
    Default VNets are VNet1 and VNet2
    Use switch parameter -CheckOnly to verify connection between VNets.

    .EXAMPLE
    Set-AzVNetConnection -VNet1Name "VNet1" -VNet2Name "VNet2" -Verbose

    #>
    [CmdletBinding()]
    param (
        [Parameter (Mandatory = $false, Position = 0)]
        [ValidatePattern("((VNet)[0-9]{1,}$)")]
        [string]$VNet1Name = "VNet1",
        [Parameter (Mandatory = $false, Position = 1)]
        [ValidatePattern("((VNet)[0-9]{1,}$)")]
        [string]$VNet2Name = "VNet2",
        [Parameter ()]
        [switch]$CheckOnly = $false
    )
    $GW1Name = -join ($VNet1Name, "_GW"); $GW2Name = -join ($VNet2Name, "_GW")
    $RG1Name = (Get-AzResource -Name $VNet1Name -ResourceGroupName Resource_Group* | Where-Object { $_.ResourceGroupName } | Select-Object -ExpandProperty ResourceGroupName)
    $RG2Name = (Get-AzResource -Name $VNet2Name -ResourceGroupName Resource_Group* | Where-Object { $_.ResourceGroupName } | Select-Object -ExpandProperty ResourceGroupName)
    $ConnectionV1toV2 = "$($VNet1Name)to$($VNet2Name)"; $ConnectionV2toV1 = "$($VNet2Name)to$($VNet1Name)"

    #get both virtual gateways
    try {
        $VNet1gw = Get-AzVirtualNetworkGateway -Name $GW1Name -ResourceGroupName $RG1Name
        $VNet2gw = Get-AzVirtualNetworkGateway -Name $GW2Name -ResourceGroupName $RG2Name
    }
    catch {
        Write-Warning "Virtual Network was not found or Resourse Group does not exist"
        throw $_
    }    

    #create VNetToVNet connections
    if (-not $CheckOnly) {
        New-AzVirtualNetworkGatewayConnection -Name $ConnectionV1toV2 -ResourceGroupName $RG1Name -VirtualNetworkGateway1 $VNet1gw `
            -VirtualNetworkGateway2 $VNet2gw -Location $Location -ConnectionType Vnet2Vnet -SharedKey "AzureEpam2020" | Out-Null
        Write-Verbose "$ConnectionV1toV2 connection is created"
        New-AzVirtualNetworkGatewayConnection -Name $ConnectionV2toV1 -ResourceGroupName $RG2Name -VirtualNetworkGateway1 $VNet2gw `
            -VirtualNetworkGateway2 $VNet1gw -Location $Location -ConnectionType Vnet2Vnet -SharedKey "AzureEpam2020" | Out-Null
        Write-Verbose "$ConnectionV2toV1 connection is created"
    }
    
    $connected = $false
    $interval = 3
    $trycount = 30

    #loop check for connection status on both sides
    while (-not $connected) {
        try {
            $resultVNet1 = Get-AzVirtualNetworkGatewayConnection -Name $ConnectionV1toV2 -ResourceGroupName $RG1Name
            $resultVNet2 = Get-AzVirtualNetworkGatewayConnection -Name $ConnectionV2toV1 -ResourceGroupName $RG2Name
        }
        catch {
            Write-Warning "Network Gateway Connection was not found or it's null"
            throw $_
        }
        if (($resultVNet1.ConnectionStatus -ne "Connected") -or ($resultVNet2.ConnectionStatus -ne "Connected")) {
            Write-Host "VNet-to-VNet connection failed. Retry in $interval seconds..." -ForegroundColor Red 
            Write-Warning "Connection status on $($VNet1Name): $($resultVNet1.ConnectionStatus)"
            Write-Warning "Connection status on $($VNet2Name): $($resultVNet2.ConnectionStatus)"
            Start-Sleep -Seconds $interval
            $trycount--
        }
        else {
            $connected = $true
            Write-Host "VNet-to-VNet connection established and running" -ForegroundColor Green
            Write-Warning "Connection status on $($VNet1Name): $($resultVNet1.ConnectionStatus)"
            Write-Warning "Connection status on $($Vnet2Name): $($resultVNet2.ConnectionStatus)"
            Start-Sleep -Seconds $interval
        }
        if ($trycount -lt 0) {
            Write-Warning "Connection check limit is exceeded"
            break
        }
    }    
}

#Set-AzVNetCreation -VNetCount 2 -SubnetCountPerVNet 2 -Location "East US 2" -Verbose
#Set-AzVNetConnection -VNet1Name "VNet1" -VNet2Name "VNet2" -Verbose
#Get-Job | Where-Object { ($_.State -eq 'Completed') -or ($_.State -eq 'Failed') } | Remove-Job