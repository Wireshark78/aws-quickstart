function New-AWSQuickStartWaitHandle {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        [string]
        $Handle,

        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSQuickStart\',

        [Parameter(Mandatory=$false)]
        [switch]
        $Base64Handle
    )

    process {
        try {
            Write-Verbose "Creating $Path"
            New-Item $Path -ErrorAction Stop

            if ($Base64Handle) {
                Write-Verbose "Trying to decode handle Base64 string as UTF8 string"
                $decodedHandle = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Handle))
                if ($decodedHandle -notlike "http*") {
                    Write-Verbose "Now trying to decode handle Base64 string as Unicode string"
                    $decodedHandle = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($Handle))
                }
                Write-Verbose "Decoded handle string: $decodedHandle"
                $Handle = $decodedHandle
            }

            Write-Verbose "Creating Handle Registry Key"
            New-ItemProperty -Path $Path -Name Handle -Value $Handle -ErrorAction Stop  
            
            Write-Verbose "Creating ErrorCount Registry Key"
            New-ItemProperty -Path $Path -Name ErrorCount -Value 0 -PropertyType dword -ErrorAction Stop                  
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function New-AWSQuickStartResourceSignal {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [string]
        $Stack,

        [Parameter(Mandatory)]
        [string]
        $Resource,

        [Parameter(Mandatory)]
        [string]
        $Region,

        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSQuickStart\'
    )

    try {
        $ErrorActionPreference = "Stop"

        Write-Verbose "Creating $Path"
        New-Item $Path

        Write-Verbose "Creating Stack Registry Key"
        New-ItemProperty -Path $Path -Name Stack -Value $Stack

        Write-Verbose "Creating Resource Registry Key"
        New-ItemProperty -Path $Path -Name Resource -Value $Resource

        Write-Verbose "Creating Region Registry Key"
        New-ItemProperty -Path $Path -Name Region -Value $Region

        Write-Verbose "Creating ErrorCount Registry Key"
        New-ItemProperty -Path $Path -Name ErrorCount -Value 0 -PropertyType dword
    }
    catch {
        Write-Verbose $_.Exception.Message
    }
}


function Get-AWSQuickStartErrorCount {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSQuickStart\'
    )

    process {
        try {            
            Write-Verbose "Getting ErrorCount Registry Key"
            Get-ItemProperty -Path $Path -Name ErrorCount -ErrorAction Stop | Select-Object -ExpandProperty ErrorCount                 
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Set-AWSQuickStartErrorCount {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        [int32]
        $Count,

        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSQuickStart\'
    )

    process {
        try {  
            $currentCount = Get-AWSQuickStartErrorCount
            $currentCount += $Count
                      
            Write-Verbose "Creating ErrorCount Registry Key"
            Set-ItemProperty -Path $Path -Name ErrorCount -Value $currentCount -ErrorAction Stop                  
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Get-AWSQuickStartWaitHandle {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSQuickStart\'
    )

    process {
        try {
            $ErrorActionPreference = "Stop"

            Write-Verbose "Getting Handle key value from $Path"
            Get-ItemProperty $Path | Select-Object -ExpandProperty Handle
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Get-AWSQuickStartResourceSignal {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSQuickStart\'
    )

    try {
        $ErrorActionPreference = "Stop"

        Write-Verbose "Getting Stack, Resource, and Region key values from $Path"
        $resourceSignal = @{
            Stack = $(Get-ItemProperty $Path | Select-Object -ExpandProperty Stack)
            Resource = $(Get-ItemProperty $Path | Select-Object -ExpandProperty Resource)
            Region = $(Get-ItemProperty $Path | Select-Object -ExpandProperty Region)
        }

        New-Object -TypeName PSObject -Property $resourceSignal
    }
    catch {
        Write-Verbose $_.Exception.Message
    }
}

function Write-AWSQuickStartEvent {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName=$true)]
        [string]
        $Message,

        [Parameter(Mandatory=$false)]
        [string]
        $EntryType = 'Error'
    )

    process {
        Write-Verbose "Checking for AWSQuickStart Eventlog Source"
        if(![System.Diagnostics.EventLog]::SourceExists('AWSQuickStart')) {
            New-EventLog -LogName Application -Source AWSQuickStart -ErrorAction SilentlyContinue
        }
        else {
            Write-Verbose "AWSQuickStart Eventlog Source exists"
        }   
        
        Write-Verbose "Writing message to application log"   
           
        try {
            Write-EventLog -LogName Application -Source AWSQuickStart -EntryType $EntryType -EventId 1001 -Message $Message
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Write-AWSQuickStartException {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        [System.Management.Automation.ErrorRecord]
        $ErrorRecord
    )

    process {
        try {
            Write-Verbose "Incrementing error count"
            Set-AWSQuickStartErrorCount -Count 1

            Write-Verbose "Getting total error count"
            $errorTotal = Get-AWSQuickStartErrorCount

            $errorMessage = "Command failure in {0} {1} on line {2} `nException: {3}" -f $ErrorRecord.InvocationInfo.MyCommand.name, 
                                                        $ErrorRecord.InvocationInfo.ScriptName, $ErrorRecord.InvocationInfo.ScriptLineNumber, $ErrorRecord.Exception.ToString()

            $handle = Get-AWSQuickStartWaitHandle -ErrorAction SilentlyContinue
            if ($handle) {
                Invoke-Expression "cfn-signal.exe -e 1 --reason='$errorMessage' '$handle'"
            } else {
                $resourceSignal = Get-AWSQuickStartResourceSignal -ErrorAction SilentlyContinue
                if ($resourceSignal) {
                    Invoke-Expression "cfn-signal.exe -e 1 --stack '$($resourceSignal.Stack)' --resource '$($resourceSignal.Resource)' --region '$($resourceSignal.Region)'"
                } else {
                    throw "No handle or stack/resource/region found in registry"
                }
            }
        }
        catch {
            Write-Verbose $_.Exception.Message
        }

        Write-AWSQuickStartEvent -Message $errorMessage        
    }
}

function Write-AWSQuickStartStatus {
    [CmdletBinding()]
    Param()

    process {   
        try {
            Write-Verbose "Checking error count"
            if((Get-AWSQuickStartErrorCount) -eq 0) {
                Write-Verbose "Getting Handle"
                $handle = Get-AWSQuickStartWaitHandle -ErrorAction SilentlyContinue
                if ($handle) {
                    Invoke-Expression "cfn-signal.exe -e 0 '$handle'"
                } else {
                    $resourceSignal = Get-AWSQuickStartResourceSignal -ErrorAction SilentlyContinue
                    if ($resourceSignal) {
                        Invoke-Expression "cfn-signal.exe -e 0 --stack '$($resourceSignal.Stack)' --resource '$($resourceSignal.Resource)' --region '$($resourceSignal.Region)'"
                    } else {
                        throw "No handle or stack/resource/region found in registry"
                    }
                }
            }
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

