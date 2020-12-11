$script:SqlExplicitRoleMembersWithInclusions = "
SELECT srm.role_principal_id AS RoleId,rp.name AS RoleName,
       srm.member_principal_id AS Id,sp.name AS AccountName,
       sp.default_database_name AS DefaultDatabaseName
FROM (sys.server_principals sp
   INNER JOIN sys.server_role_members srm ON sp.principal_id = srm.member_principal_id)
INNER JOIN sys.server_principals rp ON rp.principal_id = srm.role_principal_id
WHERE sp.type = 'S' AND sp.name NOT LIKE '##%' AND rp.name IN ({0})"

$script:AllSqlExplicitGrants = "
SELECT sp.principal_id AS Id,
       sp.name AS AccountName,
       sp.default_database_name AS DefaultDatabaseName,
       p.class_desc AS PermissionClass,
       p.type AS PermissionName,
       p.permission_name PermissionDescription,
       p.state_desc AS PermissionState
FROM sys.server_principals sp
     INNER JOIN sys.server_permissions p ON sp.principal_id = p.grantee_principal_id
WHERE sp.type = 'S' AND sp.name NOT LIKE '##%' AND (p.state = 'G' OR p.state = 'W')"

$script:SqlExplicitGrantsWithInclusions = $script:AllSqlExplicitGrants + " AND p.type IN ({0})"
$script:SqlExplicitGrantsWithExclusions = $script:AllSqlExplicitGrants + " AND p.type NOT IN ({0})"

$script:SqlServerPermissionsMap = @{
    "AAES" = "ALTER ANY EVENT SESSION"
    "ADBO" = "ADMINISTER BULK OPERATIONS"
    "AL"   = "ALTER"
    "ALAA" = "ALTER ANY SERVER AUDIT"
    "ALAG" = "ALTER ANY AVAILABILITY GROUP"
    "ALCD" = "ALTER ANY CREDENTIAL"
    "ALCO" = "ALTER ANY CONNECTION"
    "ALDB" = "ALTER ANY DATABASE"
    "ALES" = "ALTER ANY EVENT NOTIFICATION"
    "ALHE" = "ALTER ANY ENDPOINT"
    "ALLG" = "ALTER ANY LOGIN"
    "ALLS" = "ALTER ANY LINKED SERVER"
    "ALRS" = "ALTER RESOURCES"
    "ALSR" = "ALTER ANY SERVER ROLE"
    "ALSS" = "ALTER SERVER STATE"
    "ALST" = "ALTER SETTINGS"
    "ALTR" = "ALTER TRACE"
    "AUTH" = "AUTHENTICATE SERVER"
    "CADB" = "CONNECT ANY DATABASE"
    "CL"   = "CONTROL"
    "CO"   = "CONNECT"
    "COSQ" = "CONNECT SQL"
    "CRAC" = "CREATE AVAILABILITY GROUP"
    "CRDB" = "CREATE ANY DATABASE"
    "CRDE" = "CREATE DDL EVENT NOTIFICATION"
    "CRHE" = "CREATE ENDPOINT"
    "CRSR" = "CREATE SERVER ROLE"
    "CRTE" = "CREATE TRACE EVENT NOTIFICATION"
    "IAL"  = "IMPERSONATE ANY LOGIN"
    "IM"   = "IMPERSONATE"
    "SHDN" = "SHUTDOWN"
    "SUS"  = "SELECT ALL USER SECURABLES"
    "TO"   = "TAKE OWNERSHIP"
    "VW"   = "VIEW DEFINITION"
    "VWAD" = "VIEW ANY DEFINITION"
    "VWDB" = "VIEW ANY DATABASE"
    "VWSS" = "VIEW SERVER STATE"
    "XA"   = "EXTERNAL ACCESS"
    "XU"   = "UNSAFE ASSEMBLY"
}
$script:SqlServerPermissionsString = ($script:SqlServerPermissionsMap | Out-String)

function Invoke-ThrowPermissionsException
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    Write-Host -ForegroundColor Yellow $script:SqlServerPermissionsString
    Write-Host -ForegroundColor Yellow "Example Usage:"
    Write-Host -ForegroundColor Yellow "  -ExplicitPermissions @{`"Include`" = @(`"ALDB`",`"ALSS`")}"
    Write-Host -ForegroundColor Yellow "    or"
    Write-Host -ForegroundColor Yellow "  -ExplicitPermissions @{`"Exclude`" = @(`"CO`",`"COSQ`",`"VW`"}"
    Write-Host -ForegroundColor Yellow "    or (to turn it off)"
    Write-Host -ForegroundColor Yellow "  -ExplicitPermissions @{}"
    throw $Message
}

function Get-SgDiscSqlServerAccount
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$NetworkAddress,
        [Parameter(Mandatory=$false)]
        [PSCredential]$Credential = $null,
        [Parameter(Mandatory=$false)]
        [string[]]$Roles = ("sysadmin","securityadmin","serveradmin","setupadmin","processadmin","diskadmin","dbcreator","bulkadmin"),
        [Parameter(Mandatory=$false)]
        [hashtable]$ExplicitPermissions = @{"Exclude" = @("CO","COSQ","VW","VWAD","VWDB","VWSS")}
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    if (-not $Credential)
    {
        # doing this here allows error action and verbose parameters to propagate
        $Credential = (Get-SgDiscConnectionCredential $NetworkAddress)
    }

    # make sure InvokeQuery is installed
    if (-not (Get-Module InvokeQuery)) { Import-Module InvokeQuery }
    if (-not (Get-Module InvokeQuery))
    {
        throw "SQL account discovery in safeguard-discovery requires InvokeQuery.  Please using Install-Module to install InvokeQuery."
    }

    # handle explicit permissions
    if ($ExplicitPermissions -and ($ExplicitPermissions.Include -or $ExplicitPermissions.Exclude))
    {
        # extended parameter validation
        if ($ExplicitPermissions.Include -and $ExplicitPermissions.Exclude)
        {
            Invoke-ThrowPermissionsException "You must specify permissions to include or permissions to exclude permissions not both"
        }
        if ($ExplicitPermissions.Include)
        {
            $local:PermInclusions = @()
            foreach ($local:Perm in $ExplicitPermissions.Include)
            {
                if (-not $script:SqlServerPermissionsMap.ContainsKey($local:Perm))
                {
                    Invoke-ThrowPermissionsException "Invalid permission inclusion '$($local:Perm)'"
                }
                $local:PermInclusions += "'$($local:Perm)'"
            }
            $local:Sql = ($script:SqlExplicitGrantsWithInclusions -f ($local:PermInclusions -join ","))
        }
        if ($ExplicitPermissions.Exclude)
        {
            $local:PermExclusions = @()
            foreach ($local:Perm in $ExplicitPermissions.Exclude)
            {
                if (-not $script:SqlServerPermissionsMap.ContainsKey($local:Perm))
                {
                    Invoke-ThrowPermissionsException "Invalid permission exclusion '$($local:Perm)'"
                }
                $local:PermExclusions += "'$($local:Perm)'"
            }
            $local:Sql = ($script:SqlExplicitGrantsWithExclusions -f ($local:PermExclusions -join ","))
        }

        # query to find matching permissions (this is filtered to local accounts)
        $local:PrivilegedAccountsFromPermissions = (Invoke-SqlServerQuery -Sql $local:Sql -Credential $Credential -Server $NetworkAddress)
    }
    else
    {
        if ($ExplicitPermissions.Keys.Count -gt 0)
        {
            Invoke-ThrowPermissionsException "Invalid key found in ExplicitPermissions parameter"
        }
        Write-Verbose "No permission inclusions or permission exclusions found, continuing"
        $local:PrivilegedAccountsFromPermissions = @()
    }

    # handle sql server roles
    if ($Roles)
    {
        $local:RoleInclusions = @()
        foreach ($local:Role in $Roles)
        {
            $local:RoleInclusions += "'$($local:Role)'"
        }
        $local:Sql = ($script:SqlExplicitRoleMembersWithInclusions -f ($local:RoleInclusions -join ","))

        # query to find matching role memberships (this is filtered to local accounts)
        $local:PrivilegedAccountsFromRoles = (Invoke-SqlServerQuery -Sql $local:Sql -Credential $Credential -Server $NetworkAddress)
    }
    else
    {
        $local:PrivilegedAccountsFromRoles = @()
    }

    #  process results
    $local:Results = @{}
    $local:PrivilegedAccountsFromPermissions | ForEach-Object {
        if ($local:Results[$_.Id])
        {
            $local:Results[$_.Id].Permissions += (New-Object PSObject -Property ([ordered]@{
                PermissionName = $_.PermissionName;
                PermissionDescription = $_.PermissionDescription;
                PermissionClass = $_PermissionClass;
                PermissionState = $_PermissionState
            }))
        }
        else
        {
            $local:Results[$_.Id] = New-Object PSObject -Property ([ordered]@{
                AccountName = $_.AccountName;
                DefaultDatabaseName = $_.DefaultDatabaseName;
                Roles = @();
                Permissions = @(New-Object PSObject -Property ([ordered]@{
                    PermissionName = $_.PermissionName;
                    PermissionDescription = $_.PermissionDescription;
                    PermissionClass = $_PermissionClass;
                    PermissionState = $_PermissionState
                }))
            })
        }
    }
    $local:PrivilegedAccountsFromRoles | ForEach-Object {
        if ($local:Results[$_.Id])
        {
            $local:Results[$_.Id].Roles += ($_.RoleName)
        }
        else
        {
            $local:Results[$_.Id] = New-Object PSObject -Property ([ordered]@{
                AccountName = $_.AccountName;
                DefaultDatabaseName = $_.DefaultDatabaseName;
                Roles = @($_.RoleName);
                Permissions = @();
            })
        }
    }

    # convert results to an array
    $local:Results.Values | ForEach-Object { $_ }
}