param(
    [ValidateSet('Install', 'Status', 'Stop')]
    [string]$Action,
    [string]$Distro,
    [string]$LinuxUser,
    [string]$Runner
)

$ErrorActionPreference = 'Stop'

if ($Distro -notmatch '^[A-Za-z0-9_.-]+$' -or
    $LinuxUser -notmatch '^[A-Za-z0-9_.-]+$' -or
    $Runner -notmatch '^/[A-Za-z0-9_./-]+$') {
    throw 'Unsupported character in WSL distro, user, or runner path.'
}

$taskName = "TailcatOneShot-$Distro-$LinuxUser"

switch ($Action) {
    'Install' {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Enable-ScheduledTask -TaskName $taskName | Out-Null
            if ($existing.State -ne 'Running') {
                Start-ScheduledTask -TaskName $taskName
            }
            Write-Output "Existing Windows scheduled task retained: $taskName"
            return
        }

        $windowsUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $wslExe = Join-Path $env:WINDIR 'System32\wsl.exe'
        $arguments = "-d $Distro -u $LinuxUser --exec /bin/bash $Runner"
        $taskAction = New-ScheduledTaskAction -Execute $wslExe -Argument $arguments
        $atLogon = New-ScheduledTaskTrigger -AtLogOn -User $windowsUser
        $retryEveryFiveMinutes = New-ScheduledTaskTrigger -Once `
            -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 5) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -UserId $windowsUser `
            -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $taskName -Action $taskAction `
            -Trigger @($atLogon, $retryEveryFiveMinutes) `
            -Settings $settings -Principal $principal -Force | Out-Null
        Enable-ScheduledTask -TaskName $taskName | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Write-Output "Windows scheduled task started: $taskName"
    }
    'Status' {
        $task = Get-ScheduledTask -TaskName $taskName
        Write-Output "Windows scheduled task: $taskName ($($task.State))"
    }
    'Stop' {
        Disable-ScheduledTask -TaskName $taskName | Out-Null
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Output "Windows scheduled task stopped: $taskName"
    }
}
