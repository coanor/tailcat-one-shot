#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param(
    [ValidateSet('start', 'status', 'address', 'stop')]
    [string]$Action = 'start'
)

$ErrorActionPreference = 'Stop'
$serviceName = 'TailcatOneShot'
$installDir = Join-Path $env:ProgramFiles 'TailcatOneShot'
$hostExe = Join-Path $installDir 'TailcatService.exe'
$stateDir = Join-Path $installDir 'state'

function Invoke-Checked {
    param([string]$File, [string[]]$Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE." }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open Windows PowerShell as Administrator, then run .\serve.ps1 again. Installing or changing a Windows service requires elevation.'
    }
}

function Get-ManagedService {
    $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    if ($service -and ($service.PathName -ne ('"' + $hostExe + '"') -or
        $service.StartName -ne 'NT AUTHORITY\LocalService')) {
        throw "Refusing to change an unmanaged service named $serviceName."
    }
    return $service
}

function Show-Address {
    $path = Join-Path $stateDir 'address'
    if (!(Test-Path -LiteralPath $path)) { throw "No live address yet. Check $stateDir\server.log and run .\serve.ps1 status." }
    $address = (Get-Content -LiteralPath $path -Raw).Trim()
    if ($address -notmatch '^tc[A-Za-z0-9_-]{80,}$') { throw 'Invalid saved Tailcat address.' }
    Write-Output "Tailcat address (SECRET): $address"
    Write-Output "Connect from another machine: tailcat ssh $address"
}

function Install-Tailcat {
    # Use a real, pinned binary, not a user PATH shim inaccessible to LocalService.
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (!$arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'AMD64' { $arch = 'amd64'; $hash = 'f04cac07e3bf6c700b0b543df0d3315a3b312cd5a05ee76714e1cc848e9b2dff' }
        'ARM64' { $arch = 'arm64'; $hash = '1c2d081375ade2365402f9fcf611e89dbb2c5c5ee06936aaff2b205dbe427578' }
        default { throw "Unsupported Windows architecture: $arch" }
    }
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $archive = Join-Path $tempDir 'tailcat.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri "https://github.com/tailscale/tailcat/releases/download/v0.7.0/tailcat_0.7.0_windows_$arch.zip" -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $hash) {
            throw 'Tailcat archive checksum mismatch.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $tempDir
        Copy-Item -LiteralPath (Join-Path $tempDir 'tailcat.exe') -Destination $installDir
    }
    finally {
        # The target is the GUID directory created above, never a caller-supplied path.
        $resolved = [IO.Path]::GetFullPath($tempDir)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (!$resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected temporary directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function Start-TailcatService {
    Assert-Administrator
    $existing = Get-ManagedService
    if (!$existing) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        # LocalService can execute binaries, but only administrators can replace them.
        Invoke-Checked icacls.exe @($installDir, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-19:(OI)(CI)RX') | Out-Null
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        Invoke-Checked icacls.exe @($stateDir, '/grant:r', '*S-1-5-19:(OI)(CI)M') | Out-Null
        Install-Tailcat
        $compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
        Invoke-Checked $compiler @('/nologo', '/target:winexe', "/out:$hostExe", '/reference:System.ServiceProcess.dll', (Join-Path $PSScriptRoot 'windows-service.cs'))
        [IO.File]::WriteAllText((Join-Path $installDir 'arguments.txt'), 'serve --key=default no-auth-ssh')
        New-Service -Name $serviceName -BinaryPathName ('"' + $hostExe + '"') `
            -DisplayName 'Tailcat SSH (native Windows)' -StartupType Automatic `
            -Credential (New-Object PSCredential('NT AUTHORITY\LocalService', (New-Object Security.SecureString))) `
            -Description 'Managed by tailcat-one-shot. Native SSH shell as LocalService; address is secret.' | Out-Null
    }
    Set-Service -Name $serviceName -StartupType Automatic
    Invoke-Checked sc.exe @('failure', $serviceName, 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/5000') | Out-Null
    Invoke-Checked sc.exe @('failureflag', $serviceName, '1') | Out-Null
    # Start-Service is idempotent: an existing running server keeps its sessions.
    Start-Service -Name $serviceName
    $controller = Get-Service -Name $serviceName
    $controller.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $controller.Refresh()
        if ($controller.Status -ne 'Running') { throw 'Tailcat service stopped. Check its server.log.' }
        if (Test-Path -LiteralPath (Join-Path $stateDir 'address')) {
            Write-Output 'Native Windows service running; automatic startup enabled (no login required).'
            Show-Address
            return
        }
        Start-Sleep -Seconds 1
    }
    throw "Tailcat has not announced an address after 30 seconds. Check $stateDir\server.log."
}

function Main {
    switch ($Action) {
        'start' { Start-TailcatService }
        'status' {
            Assert-Administrator
            $service = Get-ManagedService
            if (!$service) { throw 'Tailcat service is not installed. Run .\serve.ps1 first.' }
            $service | Select-Object Name, State, StartMode, StartName
            if ($service.State -eq 'Running') { Show-Address }
        }
        'address' { Assert-Administrator; Show-Address }
        'stop' {
            Assert-Administrator
            $service = Get-ManagedService
            if (!$service) { throw 'Tailcat service is not installed.' }
            Set-Service -Name $serviceName -StartupType Disabled
            Stop-Service -Name $serviceName
            Remove-Item -LiteralPath (Join-Path $stateDir 'address') -Force -ErrorAction SilentlyContinue
            Write-Output 'Tailcat service stopped and automatic startup disabled. The saved key was kept.'
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Main }
