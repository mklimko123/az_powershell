Connect-AzAccount

$VNet1Name = "VNet1"
$VNet2Name = "VNet2"
$Sub1Name = "Subnet1"
$Sub2Name = "Subnet2"
$VNet1Prefix = "172.16.0.0/16"
$VNet2Prefix = "192.168.0.0/16"
$Sub1Prefix = "172.16.1.0/24"
$Sub2Prefix = "192.168.1.0/24"
$GW1SubPrefix = "172.16.255.0/27"
$GW2SubPrefix = "192.168.255.0/27"
$RG1 = "Resourse_Group1"
$RG2 = "Resourse_Group2"
$Location = "East US 2"
$GW1Name = "VNet1_GW"
$GW2Name = "VNet2_GW"
$GW1IPName = "VNet1_GW_IP"
$GW2IPName = "VNet2_GW_IP"
$GW1IPConfigName = "gw1ipconfig"
$GW2IPConfigName = "gw2ipconfig"
$ConnectionV1toV2 = "VNet1toVNet2"
$ConnectionV2toV1 = "VNet2toVNet1"


function Set-AzNetworkCreation {
    [CmdletBinding()]
    param ()

    #create resourse groups
    New-AzResourceGroup -Name $RG1 -Location $Location | Out-Null
    #Write-Verbose "$RG1 is created"
    New-AzResourceGroup -Name $RG2 -Location $Location | Out-Null
    #Write-Verbose "$RG2 is created"
    
    #create virtual networks
    $VNet1 = New-AzVirtualNetwork -ResourceGroupName $RG1 -Location $Location -Name $VNet1Name -AddressPrefix $VNet1Prefix
    Write-Verbose "$VNet1Name is created"
    $VNet2 = New-AzVirtualNetwork -ResourceGroupName $RG2 -Location $Location -Name $VNet2Name -AddressPrefix $VNet2Prefix
    Write-Verbose "$VNet2Name is created"

    #create subnets config
    Add-AzVirtualNetworkSubnetConfig -Name $Sub1Name -AddressPrefix $Sub1Prefix -VirtualNetwork $vnet1 | Out-Null
    Write-Verbose "Subnet $Sub1Prefix is created"
    Add-AzVirtualNetworkSubnetConfig -Name $Sub2Name -AddressPrefix $Sub2Prefix -VirtualNetwork $vnet2 | Out-Null
    Write-Verbose "Subnet $Sub2Prefix is created"

    #set subnet config for virtual network
    $vnet1 | Set-AzVirtualNetwork | Out-Null
    $vnet2 | Set-AzVirtualNetwork | Out-Null

    #add gateway subnets
    $vnet1 = Get-AzVirtualNetwork -ResourceGroupName $RG1 -Name $VNet1Name
    Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $GW1SubPrefix -VirtualNetwork $vnet1 | Out-Null
    Write-Verbose "Gateway subnet $GW1SubPrefix is created" 

    $vnet2 = Get-AzVirtualNetwork -ResourceGroupName $RG2 -Name $VNet2Name
    Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $GW2SubPrefix -VirtualNetwork $vnet2 | Out-Null
    Write-Verbose "Gateway subnet $GW1SubPrefix is created"

    #set gateway subnet config for virtual network
    $vnet1 | Set-AzVirtualNetwork | Out-Null
    $vnet2 | Set-AzVirtualNetwork | Out-Null

    #set public ip
    $gw1publicip = New-AzPublicIpAddress -Name $GW1IPName -ResourceGroupName $RG1 -Location $Location -AllocationMethod Dynamic
    Write-Verbose "Public IP for $GW1IPName is created"    
    $gw2publicip = New-AzPublicIpAddress -Name $GW2IPName -ResourceGroupName $RG2 -Location $Location -AllocationMethod Dynamic
    Write-Verbose "Public IP for $GW2IPName is created" 

    #set gatewate configuration
    $vnet1 = Get-AzVirtualNetwork -ResourceGroupName $RG1 -Name $VNet1Name
    $vnet2 = Get-AzVirtualNetwork -ResourceGroupName $RG2 -Name $VNet2Name

    $gw1subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet1
    $gw2subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet2

    $gw1ipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $GW1IPConfigName -SubnetId $gw1subnet.Id -PublicIpAddressId $gw1publicip.Id
    Write-Verbose "Gateway configuration for $GW1IPName is created"
    $gw2ipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $GW2IPConfigName -SubnetId $gw2subnet.Id -PublicIpAddressId $gw2publicip.Id
    Write-Verbose "Gateway configuration for $GW2IPName is created"

    #create virtual network gateway
    New-AzVirtualNetworkGateway -Name $GW1Name -ResourceGroupName $RG1 -Location $Location -IpConfigurations $gw1ipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku Basic -AsJob
    New-AzVirtualNetworkGateway -Name $GW2Name -ResourceGroupName $RG2 -Location $Location -IpConfigurations $gw2ipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku Basic -AsJob 

    Get-Job | Wait-Job | Out-Null

    Write-Verbose "$GW1Name is created"
    Write-Verbose "$GW2Name is created"

    #get both virtual gateways
    $vnet1gw = Get-AzVirtualNetworkGateway -Name $GW1Name -ResourceGroupName $RG1
    $vnet2gw = Get-AzVirtualNetworkGateway -Name $GW2Name -ResourceGroupName $RG2

    #create connections
    New-AzVirtualNetworkGatewayConnection -Name $ConnectionV1toV2 -ResourceGroupName $RG1 -VirtualNetworkGateway1 $vnet1gw -VirtualNetworkGateway2 $vnet2gw -Location $Location -ConnectionType Vnet2Vnet -SharedKey "AzureEpam2020" | Out-Null
    Write-Verbose "$ConnectionV1toV2 connection is created"
    New-AzVirtualNetworkGatewayConnection -Name $ConnectionV2toV1 -ResourceGroupName $RG2 -VirtualNetworkGateway1 $vnet2gw -VirtualNetworkGateway2 $vnet1gw -Location $Location -ConnectionType Vnet2Vnet -SharedKey "AzureEpam2020" | Out-Null
    Write-Verbose "$ConnectionV2toV1 connection is created"
}

Set-AzNetworkCreation -Verbose

$connected = $false
$interval = 3

while (-not $connected) {
    $resultVNet1 = Get-AzVirtualNetworkGatewayConnection -Name $ConnectionV1toV2 -ResourceGroupName $RG1
    $resultVNet2 = Get-AzVirtualNetworkGatewayConnection -Name $ConnectionV2toV1 -ResourceGroupName $RG2
    if (($resultVNet1.ConnectionStatus -ne "Connected") -or ($resultVNet2.ConnectionStatus -ne "Connected")) {
        Write-Host "VNet1toVNet2 connection failed" -ForegroundColor Red 
        Write-Warning "Connection status on VNet1: $($resultVNet1.ConnectionStatus)"
        Write-Warning "Connection status on VNet2: $($resultVNet2.ConnectionStatus)"
        Start-Sleep -Seconds $interval
    }
    else {
        $connected = $true
        Write-Host "VNet1toVNet2 connection established and running" -ForegroundColor Green
        Write-Warning "Connection status on VNet1: $($resultVNet1.ConnectionStatus)"
        Write-Warning "Connection status on VNet2: $($resultVNet2.ConnectionStatus)"
        Start-Sleep -Seconds $interval
    }
}