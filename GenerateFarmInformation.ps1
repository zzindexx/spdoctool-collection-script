Add-PSSnapin Microsoft.SHarePoint.PowerShell -ErrorAction SilentlyContinue
cls

$outputFilePath = "C:\farminfo\farminfo.json"

# Fram configuration section
Write-Host "Getting basic farm info..." -NoNewLine
$configDB = Get-SPDatabase | where {$_.Type -eq "Configuration Database"}


$ca = Get-SPWebApplication -IncludeCentralAdministration | where { $_.IsAdministrationWebApplication -eq $true }
$adminsite = Get-SPweb($ca.Url)
$AdminGroupName = $adminsite.AssociatedOwnerGroup
$farmAdministratorsGroup = $adminsite.SiteGroups[$AdminGroupName]

$splanguages = $adminsite.RegionalSettings.InstalledLanguages

$farmConfig = @{
    configurationDatabaseName = $configdb.Name
    configurationDatabaseServer = $configdb.Server.Name
    configurationDatabaseVersion = (Get-SPFarm).BuildVersion.ToString()
    languagePacks = @(
        $splanguages | select -ExpandProperty DisplayName
    )
    centralAdmin = @{
        url = $ca.Url
        applicationPoolId = $ca.ApplicationPool.Id
        farmAdmins = @($farmAdministratorsGroup.Users | select @{l="userName";e={$_.UserLogin}}, @{l="name";e={$_.DisplayName}})
    }
}
Write-Host "Done!"


#SQL Configuration section
$sqlConfig = @{}

Write-Host "Getting SQL Servers in farm..."
$sqlServers = @()
$realSqlServerNames = @()
$spSqlServerNames = @(Get-SPServer | where {($_.ServiceInstances | select -ExpandProperty TypeName) -contains "Microsoft SharePoint Foundation Database"} | select -ExpandProperty Address )

$spSqlServerNames | % {
    $spSqlServerName = $_
    $isAlias = $false
    $sqlServerName = $spSqlServerName

    Write-Host "    Checking server $sqlServerName"
    $allAliases = Get-Item 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo' -ErrorAction SilentlyContinue
    if ($allAliases -ne $null){
        foreach ($alias in $allAliases.Property){
            if ($alias -eq $spSqlServerName){
                $sqlServerName = $allAliases.GetValue($alias).Split(",")[1]
                Write-Host "        Is alias: true"
                Write-Host "        Real name: $sqlServerName"
                $realSqlServerNames += $sqlServerName
                $isAlias = $true
            }
        }
    }

    $ipAddresses = @(Resolve-DnsName $sqlServerName -Type A | select -ExpandProperty IPAddress)

    Write-Host "        Checking server $sqlServerName to be a Always On listener name or cluster name"
    $connectionString = "Data Source="+$sqlServerName+";Initial Catalog=master;Integrated Security=SSPI;"
    $connection = new-object system.data.SqlClient.SQLConnection($connectionString)
    $connection.Open()
    $commandHadr = new-object system.data.sqlclient.sqlcommand("SELECT SERVERPROPERTY('IsHadrEnabled')",$connection)
    $isHadr = $commandHadr.ExecuteScalar()
    

    $nodes = @()
    if ($isHadr) {
        $sqlCommand = "select replica_server_name from sys.availability_groups ag left join sys.availability_group_listeners agl on ag.group_id=agl.group_id left join  sys.availability_replicas ar on ar.group_id=ag.group_id where dns_name = '$sqlServerName' or dns_name = '$($sqlServerName.Split(".")[0])'"
        $commandNodes = new-object system.data.sqlclient.sqlcommand($sqlCommand, $connection)
        $reader = $commandNodes.ExecuteReader()
        while ($reader.Read()) {
            $nodes += $reader["replica_server_name"].ToString()
        }
    }
    $connection.Close()

    $sqlServers += @{
        name = $spSqlServerName
        ipaddresses = $ipAddresses
        isAlias = $isAlias
        sqlname = $sqlServerName
        isCluster = $isCluster -ne $null
        isAlwayson = $isHadr -ne $null
        nodes = @($nodes)
        databses = @(
            Get-SPDatabase | select Name, @{ label='Server'; expression={(&{If($_.Server.Name -ne $null) {$_.Server.Name} Else {$_.Server}}) }} | where {$_.Server -eq $spSqlServerName} | select -ExpandProperty Name
        )
    }
}
Write-Host "Done"

$sqlConfig = @{
    servers = $sqlServers
}


#SP Configuration section
$spConfig = @{}

#servers
Write-Host "Getting farm servers..." -NoNewLine
$servers = @()
$spServerNames = @(Get-SPServer | where {$_.Role -ne "Invalid" -and ($_.ServiceInstances | select -ExpandProperty TypeName) -notcontains "Microsoft SharePoint Foundation Database"} | select -ExpandProperty Address )
#$spServerNames += $realSqlServerNames 
$spServerNames | select -Unique | % {
    $spServerName =$_
    $spServerObject = Get-SPServer $spServerName
    
    $serverProducts = Get-SPProduct -Server $spServerName

    $servers += @{
        id = $spServerObject.Id
        name = $spServerObject.Address
        ipaddresses = @(Resolve-DnsName $spServerObject.Address -Type A | select -ExpandProperty IPAddress)
        products = @($serverProducts | select -ExpandProperty ProductName)
    }
}
Write-Host "Done"


Write-Host "Getting service instances..." -NoNewLine
$serviceInstances = Get-SPServiceInstance | select -ExpandProperty TypeName | select -Unique | % {
    $typeName = $_
    Get-SPServiceInstance | where {$_.TypeName -eq $typeName -and $_.Status -eq "Online"} | % {
        @{
            id = $_.Id
            name = $typeName
            serversIds = @($_.Server.Id)
        }
    }
} 



#farm solutions
Write-Host "Getting farm solutions..." -NoNewLine
$farmsolutions = @()
$farmSolutionsNames = @(Get-SPSolution | select -ExpandProperty Name)
$farmSolutionsNames | % {
    $solutionName = $_
    $solution = Get-SPSolution $solutionName

    $farmsolutions += @{
        id = $solution.SolutionId
        name = $solutionName
        deployed = $solution.Deployed
        globallydeployed = $solution.Deployed -and $solution.DeployedWebApplications.Count -eq 0
        containsGlobalAssembly = $solution.ContainsGlobalAssembly
        containsWebApplicationResource = $solution.ContainsWebApplicationResource
        deployedWebApplicationIds = @($solution.DeployedWebApplications | select -ExpandProperty id  | % { $_.ToString() }  )
    }
}
Write-Host "Done"


#Web applications
Write-Host "Getting web applications.."
$webApplications = @()
Get-SPWebApplication -IncludeCentralAdministration | % {
    $spWebApplication = $_
    $addresses = @()
    $identityProviders = @()
    $policies = @()
    $managedPaths = @()

    Write-Host "    $($spWebApplication.Url)"

    Get-SPAlternateURL -WebApplication $spWebApplication | % {
        $zone = $_
        $addresses += @{
            incomingUrl = $zone.IncomingUrl
            zone =  [string]$zone.Zone
            publicUrl = $zone.PublicUrl     

        }
    }

    [System.Enum]::GetNames([Microsoft.SharePoint.Administration.SPUrlZone]) | % {
        $zone = $_
        $identityProvider = Get-SPAuthenticationProvider -WebApplication $spWebApplication -Zone $zone -ErrorAction SilentlyContinue
        if ($identityProvider -ne $null) {
            $identityProviders += @{
                zone = $zone
                authentication = $identityProvider.DisplayName
                claimProviderName = $identityProvider.ClaimProviderName
                allowAnonymous = $identityProvider.AllowAnonymous
                disableKerberos = $identityProvider.DisableKerberos
                useWindowsIntegratedAuthentication = $identityProvider.UseWindowsIntegratedAuthentication
            }
        }
    }
    

    $spWebApplication.Policies | % {
        $spPolicy = $_
        $policies += @{
            displayName = $spPolicy.DisplayName
            username = $spPolicy.UserName
            rights = @($spPolicy.PolicyRoleBindings | select -ExpandProperty Name )
        }
    }

    Get-SPManagedPath -WebApplication $spWebApplication | % {
        $managedpath = $_
        $typeName = ""
        if ($managedpath.Type -eq 0) {
            $typeName = "ExplicitInclusion"
        } else {
            $typeName = "WildcardInclusion"
        }

        $managedPaths += @{
            name = $managedpath.Name
            type = $typeName
        }
    }


    $webApplications += @{
        id = $spWebApplication.Id
        name = $spWebApplication.DisplayName
        url = $spWebApplication.Url
        #port = $spWebApplication.Port
        applicationPoolId = $spWebApplication.ApplicationPool.Id
        serviceApplicationProxyGroupId = $spWebApplication.ServiceApplicationProxyGroup.Id 

        resourceThrottlingSettings = @{
            listViewThreshold = $spWebApplication.MaxItemsPerThrottledOperation
            listViewThresholdAdmins = $spWebApplication.MaxItemsPerThrottledOperationOverride
            maxLookupColumns = $spWebApplication.MaxQueryLookupFields
        }
        addresses = $addresses
        identityProviders = $identityProviders
        policies = $policies
        managedPaths = $managedPaths
        outgoingEmailSettings = @{
            smtpServer = $spWebApplication.OutboundMailServiceInstance.Server.Address
            smtpPort = $spWebApplication.OutboundMailPort
            senderAddress = $spWebApplication.OutboundMailSenderAddress
            replyToAddress = $spWebApplication.OutboundMailReplyToAddress
        }
    }
}
Write-Host "Done"


#Content databases
Write-Host "Getting content databases..." -NoNewLine
$contentDatabases =  Get-SPContentDatabase | select @{l='id'; e={$_.Id.ToString()}}, @{l='name'; e={$_.Name}}, @{l='server'; e={$_.Server}}, @{l='currentSiteCount'; e={$_.CurrentSiteCount}}, @{l='maximumSiteCount';e={$_.MaximumSiteCount}}, @{l='webApplicationId';e={$_.WebApplication.Id.ToString()}}, @{l='size';e={$_.DiskSizeRequired}} 
Write-Host "Done"


#Web application pools
Write-Host "Getting web application pools..." -NoNewLine
$webApplicationPools = @()
Get-SPWebApplication -IncludeCentralAdministration | select @{l='id';e={$_.ApplicationPool.Id.ToString()}}, @{l='name';e={$_.ApplicationPool.Name}}, @{l='accountId';e={$_.ApplicationPool.ManagedAccount.Id.ToString()}} | % {
    $pool = $_
    $exists = $webApplicationPools | where {$_.id -eq $pool.id}
    if ($exists -eq $null) {
        $webApplicationPools += @{
            id= $pool.id
            name= $pool.name
            accountId= $pool.accountId
        }
    }
}
Write-Host "Done"


#Managed accounts
Write-Host "Getting managed accounts..." -NoNewLine
$managedAccounts = Get-SPManagedAccount | select @{l='id';e={$_.Id.ToString()}}, @{l='name';e={$_.UserName}}, @{l='autoChangePassword';e={$_.AutomaticChange}}
Write-Host "Done"


#Service application pools
Write-Host "Getting service application pools..." -NoNewLine
$serviceApplicationPools = Get-SPServiceApplicationPool | select @{l='id';e={$_.Id.ToString()}}, @{l='name';e={$_.DisplayName}}, @{l='accountId';e={ (Get-SPManagedAccount ($_.ProcessAccount.Name)).Id.ToString()}}
Write-Host "Done"


#Service application proxy
Write-Host "Getting service application proxies..." -NoNewLine
$serviceApplicationProxies = Get-SPServiceApplicationProxy | % {
    $proxy = $_
    $serviceApplicationId = $null

    $serviceApplications = Get-SPServiceApplication
    $serviceApplications | % {
        $serviceApplication = $_
        if ($serviceApplication.IsConnected($proxy)) {
            $serviceApplicationId = $serviceApplication.Id.ToString()
        }
    }

    @{
        id = $proxy.Id.ToString()
        name = $proxy.DisplayName
        typeName = $proxy.TypeName
        serviceApplicationId = $serviceApplicationId
    }
}
Write-Host "Done"


#Service application proxy groups
Write-Host "Getting service application proxy groups.." -NoNewLine
$serviceApplicationProxyGroups = Get-SPServiceApplicationProxyGroup | % {
    $proxyGroup = $_
    @{
        id = $proxyGroup.Id.ToString()
        name = $proxyGroup.DisplayName
        proxies = @($proxyGroup.Proxies | select @{l='id';e={$_.Id.ToString()}} | select -ExpandProperty id )
    }
}
Write-Host "Done"


#Service applications
Write-Host "Getting service applications..." -NoNewLine
$serviceApplications = Get-SPServiceApplication | % {
    $sa = $_

    $saObject = @{
        id = $sa.Id.ToString()
        name = $sa.DisplayName
        typeName = $sa.TypeName
        applicationPoolId = $sa.ApplicationPool.Id
        properties = @{}
    }

    if ($sa.Database -ne $null) {
        $saObject.databaseName = $sa.Database.Name
        $saObject.databaseServer = $sa.Database.Server.Address
    }

    $saObject
}
Write-Host "Done"


#Site collections
Write-Host "Getting site collections.."
$siteCollections = @()
Get-SPWebApplication | % {
    $webApp = $_
    Write-Host "    Web application - $($webApp.Url).."
    Get-SPSite -WebApplication $webApp -Limit All | % {
        $siteCollection = $_
        $siteCollections += @{
            id = $siteCollection.Id.ToString()
            name = $siteCollection.RootWeb.Title
            url = $siteCollection.Url
            contentDatabaseId = $siteCollection.ContentDatabase.Id 
            size =  $siteCollection.Usage.Storage
        }
    }
}
Write-Host "Done"



$spConfig = @{
    servers = $servers
    serviceInstances = $serviceInstances
    farmSolutions = $farmsolutions
    contentDatabases = $contentDatabases
    webApplications = $webApplications
    webApplicationPools = $webApplicationPools
    managedAccounts = $managedAccounts
    serviceApplicationPools = $serviceApplicationPools
    serviceApplicationProxies = $serviceApplicationProxies
    serviceApplicationProxyGroups = $serviceApplicationProxyGroups
    serviceApplications = $serviceApplications
    siteCollections = $siteCollections
}


$farmConfigurationJson = @{
    farmConfig = $farmConfig
    sqlConfig = $sqlConfig
    spConfig = $spConfig
}

$farmConfigurationJson | ConvertTo-Json -Depth 100 | Out-File $outputFilePath
