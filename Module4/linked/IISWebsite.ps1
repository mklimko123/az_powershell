Configuration IISWebsite 
{

    param (
        [Parameter(Mandatory = $true)]
        [string]$nodeName
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'xWebAdministration'
    Import-DscResource -ModuleName 'xNetworking'

    Node $nodeName
    {
        WindowsFeature IIS {
            Name   = "Web-Server"
            Ensure = "Present"
        }

        WindowsFeature ASPNet45 {
            Ensure = "Present"
            Name   = "Web-Asp-Net45"
        }

        WindowsFeature IISManagementConsole {
            Ensure = "Present"
            Name   = "Web-Mgmt-Console"
        }

        File index.html {
            Ensure          = "Present"
            DestinationPath = "C:\inetpub\wwwroot\index.html"
            Contents        = "<html> <body> <p> <b>IIS Web-Server:</b> $nodeName </p> </body></html>"
            Force           = $true
            DependsOn       = "[WindowsFeature]IIS"
        }

        xWebSite NewWebsite {
            Ensure       = "Present"
            DependsOn    = "[WindowsFeature]IIS"
            Name         = "Default Web Site"
            State        = "Started"
            PhysicalPath = "C:\inetpub\wwwroot\"

            BindingInfo  = MSFT_xWebBindingInformation {
                Protocol  = "HTTP"
                Port      = "8080"
                IPAddress = "*"
            }
        }

        xFirewall HTTP8080in {
            DependsOn   = "[xWebSite]NewWebsite"
            Ensure      = "Present"
            Name        = 'HTTP8080in'
            DisplayName = 'Allow Inbound TCP 8080 (TCP-in)'
            Action      = 'Allow'
            Direction   = 'Inbound'
            LocalPort   = ('8080')
            Protocol    = 'TCP'
            Profile     = 'Any'
            Enabled     = 'True'
        }
    }
}