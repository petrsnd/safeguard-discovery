<#
.SYNOPSIS
Discover privileged Assets on an ESX server.

.DESCRIPTION
This cmdlet may be used to discover privileged Assets on an ESX server.

When a credential is not supplied to this cmdlet, it will automatically look for an open
access request with a matching asset name or network address and use that access request
to get the password to run the discovery.  If no access request is found, the cmdlet
will prompt for an Asset name and password to use.

.PARAMETER NetworkAddress
IP address or hostname of a Esx database.

.PARAMETER Credential
A PowerShell credential object that can be used to connect to the database server to
execute the discovery job.

.INPUTS
None.

.OUTPUTS
System.Management.Automation.PSObject.

.EXAMPLE
Get-SgDiscEsxAsset esx.test.env

.EXAMPLE
Get-SgDiscEsxAsset esx.test.env -Credential (Get-Credential)
#>
function Get-SgDiscEsxAsset
{
    [CmdletBinding(DefaultParameterSetName="ExcludePerms")]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$NetworkAddress,
        [Parameter(Mandatory=$false)]
        [PSCredential]$Credential = $null
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    if (-not $Credential)
    {
        # doing this here allows error action and verbose parameters to propagate
        $Credential = (Get-SgDiscConnectionCredential $NetworkAddress)
    }

    # make sure VMware.VimAutomation.Core is installed
    if (-not (Get-Module VMware.VimAutomation.Core))
    { 
        try 
        {
            Import-Module VMware.VimAutomation.Core
        }
        catch 
        {
            throw "ESX Asset discovery in safeguard-discovery requires VMware.VimAutomation.Core.  Please run: Install-Module VMware.VimAutomation.Core."
        }
    }

    (Set-PowerCLIConfiguration -Confirm:$false -InvalidCertificateAction Ignore) > $null
    $local:server = Connect-VIServer $NetworkAddress -Credential $Credential

    $local:Results = @()
    $local:systems = Get-VM -Server $local:server | ForEach-Object { Get-VMGuest -Server $local:server $_.Name }
    foreach ($local:system in $local:systems)
    {  
        if ($local:system.OSFullName)
        {
            $local:OS = $local:system.OSFullName
        } 
        else 
        {
            $local:OS =  $local:system.ConfiguredGuestId
        }

        $local:networkAddress = $null
        if ($local:system.IPAddress)
        {
            $local:ipv4 = $local:system.IPAddress | ForEach-Object { [IpAddress] $_ } | Where-Object { $_.AddressFamily -eq 'InterNetwork'}
            if ($local:ipv4)
            {
                $local:networkAddress = $local:ipv4[0]
            }
        }

        $local:Results += New-Object PSObject -Property ([ordered]@{
            AssetName = $local:system.VmName;
            State = $local:system.State
            OperatingSystem = $local:OS;
            HostName = $local:system.HostName;
            IpAddress = $local:networkAddress;
            Description = "safeguard-discovery"
        })
    }

    $local:Results
}
