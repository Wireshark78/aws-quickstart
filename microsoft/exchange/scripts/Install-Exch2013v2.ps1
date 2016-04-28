[CmdletBinding()]
param(
    [string]
    [Parameter(Mandatory=$true, Position=0)]
    $InstallPath,

    [int]
    [Parameter(Mandatory=$false, Position=1)]
    $Server = 1,

    [string]
    $DAGSize
)
try {
    Start-Transcript -Path c:\cfn\log\Install-Exchange2013.ps1.txt

    Write-Verbose "Starting Install"
    $InstallPath = Join-Path -Path $InstallPath -ChildPath Setup.exe
    Invoke-Expression "$InstallPath /mode:Install /role:ClientAccess,Mailbox /MdbName:DefaultDB$Server /DbFilePath:'C:\DefaultDB\DefaultDB$Server\DefaultDB$Server.edb' /LogFolderPath:'C:\DefaultDB\DefaultDB$Server' /InstallWindowsComponents /IAcceptExchangeServerLicenseTerms" -ErrorAction Stop

    Invoke-Command -ScriptBlock {repadmin /syncall /A /e /P} -ComputerName (([ADSI]”LDAP://RootDSE”).dnshostname)

    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultUserName
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword

    Add-PSSnapin Microsoft.Exchange.Management.PowerShell.E2010

    Start-BitsTransfer -Source "https://s3.amazonaws.com/quickstart-reference/microsoft/exchange/latest/scripts/$($DAGSize)SCRIPTS.zip" -Destination c:\cfn\scripts\
    c:\cfn\scripts\Unzip-Archive.ps1 -Source "c:\cfn\scripts\$($DAGSize)SCRIPTS.zip" -Destination "C:\cfn\scripts\$($DAGSize)SCRIPTS"

    CD "c:\cfn\scripts\$($DAGSize)SCRIPTS"

    .\Diskpart.ps1 -ServerFile "C:\cfn\scripts\$($DAGSize)SCRIPTS\Servers.csv" -PrepareAutoReseedVolume

    if($env:COMPUTERNAME -eq 'EXCH4') {
        .\CreateDAG.ps1 -ServerFile "C:\cfn\scripts\$($DAGSize)SCRIPTS\DAGInfo.csv" -NewDAG DAG1
        .\CreateMBDatabases.ps1 -DBFile .\MailboxDatabases.csv
        .\CreateMBDatabaseCopies.ps1 -DBCopyFile .\MailboxDatabaseCopies.csv -DBFile .\MailboxDatabases.csv
    }

    Write-Verbose "Sending CFN Signal @ $(Get-Date)"
    Write-AWSQuickStartStatus -Verbose
}
catch {
    $_ | Write-AWSQuickStartException
}
