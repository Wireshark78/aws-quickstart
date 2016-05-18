[CmdletBinding()]
param(
    [string]
    $DomainDNSName,

    [string]
    $DCName,

    [string]
    $DomainNetBIOSName,

    [string]
    $FEIPAddress1,

    [string]
    $FEIPAddress2,

    [switch]
    $FirstFrontEnd,

    [string]
    $IncludeEdge,

    [string]
    $Edge1InternalIPAddress,

    [string]
    $Edge2InternalIPAddress,

    [string]
    $Edge1ExternalIPAddress,

    [string]
    $Edge2ExternalIPAddress
)

try {
    Start-Transcript -Path c:\cfn\log\Install-Lync2013.ps1.txt

    $driveLetter = Get-Volume | ?{$_.DriveType -eq 'CD-ROM'} | select -ExpandProperty DriveLetter
    if ($driveLetter.Count -gt 1) {
        throw "More than 1 mounted ISO found"
    }

    Write-Verbose "Installing Lync pre-requisites @ $(Get-Date)"

    Start-Process "$($driveLetter):\Setup\amd64\vcredist_x64.exe" '/q' -NoNewWindow -Wait
    Start-Process msiexec.exe "/i $($driveLetter):\Setup\amd64\Setup\ocscore.msi /qn" -NoNewWindow -Wait
    Start-Process msiexec.exe "/i $($driveLetter):\Setup\amd64\SQLSysClrTypes.msi /qn" -NoNewWindow -Wait
    Start-Process msiexec.exe "/i $($driveLetter):\Setup\amd64\SharedManagementObjects.msi /qn" -NoNewWindow -Wait
    Start-Process msiexec.exe "/i $($driveLetter):\Setup\amd64\Setup\admintools.msi /qn" -NoNewWindow -Wait
    Start-Process C:\cfn\downloads\Silverlight_x64.exe '/q' -NoNewWindow -Wait

    Import-Module "C:\Program Files\Common Files\Microsoft Lync Server 2013\Modules\Lync\Lync.psd1"

    if($FirstFrontEnd) {
        Write-Verbose "Preparing Active Directory for Lync @ $(Get-Date)"

        Install-CSAdServerSchema -Confirm:$false -Verbose -Report "C:\cfn\log\Install-CSAdServerSchema.html"
        Enable-CSAdForest  -Verbose -Confirm:$false -Report "C:\cfn\log\Enable-CSAdForest.html"
        Enable-CSAdDomain -Verbose -Confirm:$false -Report "C:\cfn\log\Enable-CSAdDomain.html"
        Add-ADGroupMember -Identity CSAdministrator -Members "Domain Admins"
        Add-ADGroupMember -Identity RTCUniversalServerAdmins -Members "Domain Admins"

        Invoke-Command -ScriptBlock {repadmin /syncall /A /e /P} -ComputerName $DCName
    }

    Write-Verbose "Creating file shares for std. edition pool @ $(Get-Date)"

    New-Item -ItemType directory -Path c:\lyncshare
    New-SmbShare -Name lyncshare -Path c:\lyncshare -FullAccess everyone

    Get-SmbShare -Name lyncshare | Grant-SmbShareAccess -AccountName "$DomainNetBIOSName\RTCComponentUniversalServices" -AccessRight full -Confirm:$false -Force
    Get-SmbShare -Name lyncshare | Grant-SmbShareAccess -AccountName "$DomainNetBIOSName\RTCHSUniversalServices" -AccessRight full -Confirm:$false -Force
    Get-SmbShare -Name lyncshare | Grant-SmbShareAccess -AccountName "$DomainNetBIOSName\RTCUniversalConfigReplicator" -AccessRight full -Confirm:$false -Force
    Get-SmbShare -Name lyncshare | Grant-SmbShareAccess -AccountName "$DomainNetBIOSName\RTCUniversalServerAdmins" -AccessRight full -Confirm:$false -Force       
    
    if($FirstFrontEnd) {
        Write-Verbose "Detected FirstFrontEnd switch...Preparing Std. Edition Server Lync FE1 and publishing the topology @ $(Get-Date)"

        Start-Process "$($driveLetter):\Setup\amd64\SQLEXPR_x64.exe" '/QUIET /IACCEPTSQLSERVERLICENSETERMS /HIDECONSOLE /ACTION=Install /FEATURES=SQLEngine,Tools /INSTANCENAME=RTC /TCPENABLED=1 /SQLSVCACCOUNT="NT AUTHORITY\NetworkService" /SQLSYSADMINACCOUNTS="Builtin\Administrators" /BROWSERSVCSTARTUPTYPE="Automatic" /AGTSVCACCOUNT="NT AUTHORITY\NetworkService" /SQLSVCSTARTUPTYPE=Automatic' -NoNewWindow -Wait

        Install-CsDatabase -CentralManagementDatabase -SqlServerFqdn "fe1.$DomainDNSName" -SqlInstanceName rtc -DatabasePaths 'D:\Logs','D:\Data' -Report 'C:\cfn\log\InstallDatabases.html'
        Set-CsConfigurationStoreLocation -SqlServerFqdn "fe1.$DomainDNSName" -SqlInstanceName rtc -Report 'C:\cfn\log\Set-CsConfigurationStoreLocation.html'    
        
        if($IncludeEdge -eq 'true') {
            $topology = Get-Content C:\cfn\scripts\topology-edge.xml

            $topology  = $topology.Replace('Edge1InternalIP',$Edge1InternalIPAddress)
            $topology  = $topology.Replace('Edge1ExternalIP',$Edge1ExternalIPAddress)

            $topology  = $topology.Replace('Edge2InternalIP',$Edge2InternalIPAddress)
            $topology  = $topology.Replace('Edge2ExternalIP',$Edge2ExternalIPAddress)

            Set-Content -Path C:\cfn\scripts\topology.xml -Value $topology

            Enable-WsManCredSSP –Role Server -Force
            Enable-WsManCredSSP –DelegateComputer * -Role Client -Force
        }
        else {
            $topology = Get-Content C:\cfn\scripts\topology.xml
        }

        if($DomainDNSName -ne 'example.com') {
            $topology  = $topology.Replace('example.com',$DomainDNSName)
            Set-Content -Path C:\cfn\scripts\topology.xml -Value $topology -Force
        }

        Publish-CSTopology -Filename C:\cfn\scripts\topology.xml -Force
    }
    else{
        Write-Verbose "Preparing Std. Edition Server Lync FE2 @ $(Get-Date)"
        Start-Process "$($driveLetter):\Setup\amd64\SQLEXPR_x64.exe" '/QUIET /IACCEPTSQLSERVERLICENSETERMS /HIDECONSOLE /ACTION=Install /FEATURES=SQLEngine,Tools /INSTANCENAME=RTC /TCPENABLED=1 /SQLSVCACCOUNT="NT AUTHORITY\NetworkService" /SQLSYSADMINACCOUNTS="Builtin\Administrators" /BROWSERSVCSTARTUPTYPE="Automatic" /AGTSVCACCOUNT="NT AUTHORITY\NetworkService" /SQLSVCSTARTUPTYPE=Automatic' -NoNewWindow -Wait
        Install-CsDatabase -CentralManagementDatabase -SqlServerFqdn "fe2.$DomainDNSName" -SqlInstanceName rtc -DatabasePaths 'D:\Logs','D:\Data' -Report 'C:\cfn\log\InstallDatabases.html'
    }

    Enable-CSTopology

    Write-Verbose "Installing local configuration store @ $(Get-Date)"

    cd "C:\Program Files\Microsoft Lync Server 2013\Deployment"
    .\Bootstrapper.exe /BootstrapLocalMgmt "/SourceDirectory:$($driveLetter):\Setup\amd64"

    Write-Verbose "Installing Lync  @ $(Get-Date)"

    $CSconfigExp = Export-csconfiguration -asbytes
    Import-CSConfiguration -Byteinput $CSconfigExp -Localstore
    .\Bootstrapper.exe "/SourceDirectory:$($driveLetter):\Setup\amd64"

    if($FirstFrontEnd) {
        Install-CSDatabase -ConfiguredDatabases -SqlServerFqdn "fe1.$DomainDNSName" -DatabasePaths "D:\Logs","D:\Data"
    }
    else {
        Install-CSDatabase -ConfiguredDatabases -SqlServerFqdn "fe2.$DomainDNSName" -DatabasePaths "D:\Logs","D:\Data"
    }

    if($FirstFrontEnd) {
        Write-Verbose "Creating all DNS records for Lync @ $(Get-Date)"

        Add-DnsServerResourceRecord -Srv -Name _sipinternaltls._tcp -ZoneName $DomainDNSName –DomainName "fe1.$DomainDNSName" –Priority 0 –Weight 0 –Port 5061 -Computername $DCName
        Add-DnsServerResourceRecord -Srv -Name _sipinternaltls._tcp -ZoneName $DomainDNSName –DomainName "fe2.$DomainDNSName" –Priority 0 –Weight 0 –Port 5061 -Computername $DCName
        Add-DnsServerResourceRecordA -Name meet -ZoneName $DomainDNSName -IPv4Address $FEIPAddress1 -Computername $DCName
        Add-DnsServerResourceRecordA -Name admin -ZoneName $DomainDNSName -IPv4Address $FEIPAddress1 -Computername $DCName
        Add-DnsServerResourceRecordA -Name dialin -ZoneName $DomainDNSName -IPv4Address $FEIPAddress1 -Computername $DCName   
        Add-DnsServerResourceRecordA -Name sip -ZoneName $DomainDNSName -IPv4Address $FEIPAddress1 -Computername $DCName  
    }
    else {
        Write-Verbose "Creating sip host record for Lync FE2 @ $(Get-Date)"
        Add-DnsServerResourceRecordA -Name sip -ZoneName $DomainDNSName -IPv4Address $FEIPAddress2 -Computername $DCName
    }

    if($IncludeEdge) {
        Add-DnsServerResourceRecordA -Name LE1 -ZoneName $DomainDNSName -IPv4Address $Edge1InternalIPAddress -Computername $DCName
        Add-DnsServerResourceRecordA -Name LE2 -ZoneName $DomainDNSName -IPv4Address $Edge2InternalIPAddress -Computername $DCName
    }

    Write-Verbose "Installing certificates @ $(Get-Date)"
    $Certificate = Request-CsCertificate -New -Type Default,WebServicesInternal,WebServicesExternal -CA "$DCName.$DomainDNSName\$DomainNetBIOSName-$DCName-CA" -FriendlyName Lync -AllSipDomain
    Set-CsCertificate -Thumbprint $Certificate.Thumbprint -Type Default,WebServicesInternal,WebServicesExternal
    
    if($FirstFrontEnd) {
        $OauthCert = Request-CsCertificate -New -Type OAuthTokenIssuer -CA "$DCName.$DomainDNSName\$DomainNetBIOSName-$DCName-CA" -FriendlyName OAuth -AllSipDomain
        Set-CsCertificate -Thumbprint $OauthCert.Thumbprint -Type OAuthTokenIssuer 
        
        $urlEntry = New-CsSimpleUrlEntry -Url "https://dialin.$DomainDNSName"
        $simpleUrl = New-CsSimpleUrl -Component "dialin" -Domain "*" -SimpleUrlEntry $urlEntry -ActiveUrl "https://dialin.$DomainDNSName"

        $urlEntry2 = New-CsSimpleUrlEntry -Url "https://meet.$DomainDNSName"
        $simpleUrl2 = New-CsSimpleUrl -Component "meet" -Domain "$DomainDNSName" -SimpleUrlEntry $urlEntry2 -ActiveUrl "https://meet.$DomainDNSName"

        Set-CsSimpleUrlConfiguration -Identity "Global" -SimpleUrl @{Add=$simpleUrl,$simpleUrl2}           
    }    

    Enable-CsComputer

    Write-Verbose "Turning off IESC  @ $(Get-Date)"
    $key1 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
    $key2 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"

    Set-ItemProperty -Path $key1 -Name IsInstalled -Value 0
    Set-ItemProperty -Path $key2 -Name IsInstalled -Value 0

    Write-Verbose "Adding *.$DomainDNSName to local intranet zone @ $(Get-Date)"
    New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$DomainDNSName"
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$DomainDNSName" -Name * -Value 1 -Type DWord
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap" -Name IEHarden -Value 0 -Type DWord

    Write-Verbose "Sending CFN Signal @ $(Get-Date)"
    Write-AWSQuickStartStatus -Verbose

    if(!$FirstFrontEnd) {
        Invoke-Command -ScriptBlock { Restart-Computer -Force } -ComputerName fe1,fe2
    }
}
catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-AWSQuickStartException
}