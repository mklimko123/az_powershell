Configuration IISWebsite
{
    Param (
        [string] $NodeName
	)

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName xNetworking -ModuleVersion "5.7.0.0"
    Import-DscResource -ModuleName xWebAdministration -ModuleVersion "3.1.1"

    Node $NodeName
    {
        xFirewall Firewall
        {
            Name                  = 'IIS8080'
            DisplayName           = 'IIS8080'
            Description           = 'Firewall Rule allows 8080 port for IIS'
            Group                 = 'IIS rules'
            Ensure                = 'Present'
            Enabled               = 'True'
            Direction             = 'Inbound'
            LocalPort             = '8080'
            Protocol              = 'TCP'
        }

        WindowsFeature WebServer {
            Ensure = "Present"
            Name   = "Web-Server"
        }
     
        WindowsFeature WebMgmtTools {
            Ensure = 'Present'
            Name   = "Web-Mgmt-Tools"
        }
        
        xWebsite DefaultSite
        {
            Ensure          = "Present"
            Name            = "Default Web Site"
            State           = "Started"
            PhysicalPath    = $Node.DefaultWebSitePath
            BindingInfo     = @(
                MSFT_xWebBindingInformation
                {
                    Protocol              = "HTTP"
                    Port                  = 8080
                }
            )
            DependsOn       = "[WindowsFeature]WebServer"
        }
      
        File index.htm
        {
            DestinationPath = "C:\inetpub\wwwroot\index.htm"
            Contents        = "<head></head><body><p> Task 9 !NodeName: $NodeName!</p></body>"
            Checksum        ='SHA-256'
            Force           = $true
            DependsOn       = "[WindowsFeature]WebServer" 
        }
    }
}