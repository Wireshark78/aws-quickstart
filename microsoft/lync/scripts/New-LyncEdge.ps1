[CmdletBinding()]
param(
    [string]
    $DomainDNSName,

    [string]
    $DomainNetBIOSName,

    [string]
    $DCName,

    [string]
    $Username,

    [string]
    $Password,

    [string]
    $Edge1EIP,

    [string]
    $Edge2EIP,

    [switch]
    $FirstEdge
)

try {
    Start-Transcript -Path c:\cfn\log\New-LyncEdge.ps1.txt

    Enable-WsManCredSSP –Role Client –DelegateComputer * -Force

    New-Item -ItemType directory -Name downloads -Path c:\cfn

    $Pass = ConvertTo-SecureString $Password -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential -ArgumentList "$Username@$DomainDNSName", $Pass

    if($FirstEdge) {
        Invoke-Command -ScriptBlock {
            param(
                $Edge1EIP,
                $Edge2EIP,
                $DCName
            )

            $topology = Get-Content C:\cfn\scripts\topology.xml
            $topology  = $topology.Replace('1.1.1.1',$Edge1EIP)
            $topology  = $topology.Replace('2.2.2.2',$Edge2EIP)
            Set-Content -Path C:\cfn\scripts\topology.xml -Value $topology -Force
            Publish-CSTopology -Filename C:\cfn\scripts\topology.xml -Force
            Export-CsConfiguration -FileName "\\$DCName\c`$\inetpub\wwwroot\lync.zip" -Force

        } -ComputerName "fe1.$DomainDNSName" -Authentication CredSSP -Credential $Credential -ArgumentList $Edge1EIP,$Edge2EIP,$DCName
    }

    Write-Verbose "Importing root certificate from CA"

    Start-BitsTransfer -Source "http://$DCName.$DomainDNSName/cert.crt" -Destination c:\cfn\downloads
    Import-Certificate -FilePath c:\cfn\downloads\cert.crt -CertStoreLocation Cert:\LocalMachine\Root

    Write-Verbose "Downloading Lync configuration"

    Start-BitsTransfer -Source "http://$DCName.$DomainDNSName/lync.zip" -Destination c:\cfn\downloads

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

    Import-Module "C:\Program Files\Common Files\Microsoft Lync Server 2013\Modules\Lync\Lync.psd1"

    Write-Verbose "Installing local configuration store @ $(Get-Date)"

    cd "C:\Program Files\Microsoft Lync Server 2013\Deployment"
    .\Bootstrapper.exe /BootstrapLocalMgmt "/SourceDirectory:$($driveLetter):\Setup\amd64"

    Enable-CSReplica -Verbose -Confirm:$false -Report "C:\cfn\log\Enable-CSReplica.html"

    Write-Verbose "Installing Lync  @ $(Get-Date)"

    Import-CsConfiguration -FileName c:\cfn\downloads\lync.zip -LocalStore
    .\Bootstrapper.exe "/SourceDirectory:$($driveLetter):\Setup\amd64"

    $internalCert = Request-CSCertificate -New -Type Internal -CA "$DCName.$DomainDNSName\$DomainNetBIOSName-$DCName-CA" -Country US -State "WA" -City "Seattle" -FriendlyName "Edge Internal" -KeySize 2048 -PrivateKeyExportable $False -Organization "AWS" -OU "AWS" -CAAccount "$Username@$DomainDNSName" -CAPassword $Password
    Set-CsCertificate -Thumbprint $internalCert.Thumbprint -Type Internal

    $externalCert = Request-CSCertificate -New -Type AccessEdgeExternal,DataEdgeExternal,AudioVideoAuthentication,XmppServer -CA "$DCName.$DomainDNSName\$DomainNetBIOSName-$DCName-CA" -Country US -State "WA" -City "Seattle" -FriendlyName "Edge External" -KeySize 2048 -PrivateKeyExportable $True -Organization "AWS" -OU "AWS" -DomainName "sip.$DomainDNSName" -CAAccount "$Username@$DomainDNSName" -CAPassword $Password -AllSipDomain -Verbose
    Set-CSCertificate -Type AccessEdgeExternal,DataEdgeExternal,AudioVideoAuthentication,XmppServer -Thumbprint $externalCert.Thumbprint -Confirm:$false 

    Write-Verbose "Sending CFN Signal @ $(Get-Date)"
    Write-AWSQuickStartStatus -Verbose

    c:\cfn\scripts\Disable-AutoLogon.ps1
    Restart-Computer -Force
}
catch{
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-AWSQuickStartException
}