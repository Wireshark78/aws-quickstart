param(
    [Parameter(Mandatory=$true)]
    [string]$VPCCIDR,

    [Parameter(Mandatory=$true)]
    [string[]]$DNSAddresses,

    [Parameter(Mandatory=$true)]
    [string]$ExternalIPAddress,

    [Parameter(Mandatory=$true)]
    [string]$InternalIPAddress
)

try {
    $ErrorActionPreference = "Stop"

    #Discover and Rename adapters
    $extIPAddress = Get-NetIPAddress -AddressFamily IPv4 | ?{$_.IPAddress -eq $ExternalIPAddress}
    $intIPAddress = Get-NetIPAddress -AddressFamily IPv4 | ?{$_.IPAddress -eq $InternalIPAddress}

    $tries = 1
    $maxTries = 60
    $sleep = 15
    # 60 tries with 15 second sleeps = approx 15 minutes
    while (-not $extIPAddress -or -not $intIPAddress) {
        if ($tries -ge $maxTries) {
            throw "Timed out waiting for ENI to become ready within the instance"
        }

        Write-Host "($tries out of $maxTries tries): Waiting for both addresses to be available. Sleeping for $sleep seconds..."
        Start-Sleep -Seconds $sleep

        $extIPAddress = Get-NetIPAddress -AddressFamily IPv4 | ?{$_.IPAddress -eq $ExternalIPAddress}
        $intIPAddress = Get-NetIPAddress -AddressFamily IPv4 | ?{$_.IPAddress -eq $InternalIPAddress}
        $tries += 1
    }

    Rename-NetAdapter -Name $extIPAddress.InterfaceAlias -NewName External
    Rename-NetAdapter -Name $intIPAddress.InterfaceAlias -NewName Internal

    #Gather configuration
    $extIPConfig = Get-NetIPConfiguration -InterfaceAlias External
    $intIPConfig = Get-NetIPConfiguration -InterfaceAlias Internal
    $extIPAddress = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias External | ?{$_.IpAddress -eq $ExternalIPAddress}
    $intIPAddress = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias Internal | ?{$_.IpAddress -eq $InternalIPAddress}

    #Set static addresses/route
    Get-NetAdapter | Set-NetIPInterface -DHCP Disabled
    Get-NetAdapter External | New-NetIPAddress -AddressFamily IPv4 -IPAddress $extIPAddress.IPAddress -PrefixLength $extIPAddress.PrefixLength -DefaultGateway $extIPConfig.IPv4DefaultGateway.NextHop
    Get-NetAdapter Internal | New-NetIPAddress -AddressFamily IPv4 -IPAddress $intIPAddress.IPAddress -PrefixLength $intIPAddress.PrefixLength

    Invoke-Expression "netsh interface ipv4 add route $VPCCIDR internal $($intIPConfig.IPv4DefaultGateway.NextHop)"

    Get-NetAdapter | Set-DnsClientServerAddress -ServerAddresses $DNSAddresses
}
catch {
    $_ | Write-AWSQuickStartException
}