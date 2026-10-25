#Requires -Version 5.1
param([string]$TailcatBinary)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\serve.ps1')

function Assert($Condition, $Message) {
    if (!$Condition) { throw "FAIL: $Message" }
}
function Wait-Until([scriptblock]$Condition, [string]$Message) {
    for ($i = 0; $i -lt 80; $i++) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 250
    }
    throw "FAIL: timed out: $Message"
}

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('tailcat-test-' + [Guid]::NewGuid())
$hostProcess = $null
New-Item -ItemType Directory -Path $testDir | Out-Null
try {
    $compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    $testHost = Join-Path $testDir 'TailcatService.exe'
    Invoke-Checked $compiler @('/nologo', '/target:exe', "/out:$testHost", '/reference:System.ServiceProcess.dll', (Join-Path $PSScriptRoot '..\windows-service.cs'))
    $fixture = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
class FakeTailcat {
    static void Main(string[] args) {
        string state = Environment.GetEnvironmentVariable("HOME");
        string key = Path.Combine(Environment.GetEnvironmentVariable("APPDATA"), @"tailcat\keys\default.private.json");
        if (args[0] == "genkey") {
            Directory.CreateDirectory(Path.GetDirectoryName(key));
            File.WriteAllText(key, "fixture-key");
            File.AppendAllText(Path.Combine(state, "generations"), "1");
            return;
        }
        if (!File.Exists(key)) Environment.Exit(2);
        File.AppendAllText(Path.Combine(state, "starts"), "1");
        File.WriteAllText(Path.Combine(state, "child.pid"), Process.GetCurrentProcess().Id.ToString());
        Console.WriteLine("Server listening with saved key: tc" + new string('A', 100));
        Thread.Sleep(1500); // Exit deliberately to exercise the restart loop.
    }
}
'@
    $fixturePath = Join-Path $testDir 'fixture.cs'
    [IO.File]::WriteAllText($fixturePath, $fixture)
    Invoke-Checked $compiler @('/nologo', '/target:exe', "/out:$(Join-Path $testDir 'tailcat.exe')", $fixturePath)
    [IO.File]::WriteAllText((Join-Path $testDir 'arguments.txt'), 'serve --key=default no-auth-ssh')
    $hostProcess = Start-Process -FilePath $testHost -ArgumentList '--console' -WindowStyle Hidden -PassThru
    $testState = Join-Path $testDir 'state'
    Wait-Until { Test-Path (Join-Path $testState 'address') } 'live address'
    Assert ((Get-Content (Join-Path $testState 'address') -Raw) -eq ('tc' + ('A' * 100))) 'address extraction'
    Wait-Until { (Get-Content (Join-Path $testState 'starts') -Raw).Length -ge 2 } 'restart after child exits'
    Assert ((Get-Content (Join-Path $testState 'generations') -Raw) -eq '1') 'saved key reused across restarts'
    Wait-Until { Test-Path (Join-Path $testState 'address') } 'address after restart'
    $childId = [int](Get-Content (Join-Path $testState 'child.pid'))
    Stop-Process -Id $hostProcess.Id -Force
    $hostProcess.WaitForExit()
    Wait-Until { !(Get-Process -Id $childId -ErrorAction SilentlyContinue) } 'child killed when service host crashes'

    # Verify installer policy without requiring elevation or changing real services.
    $installDir = $testDir
    $hostExe = $testHost
    $stateDir = $testState
    $script:fakeService = [pscustomobject]@{ PathName = ('"' + $hostExe + '"'); StartName = 'NT AUTHORITY\LocalService' }
    function Get-CimInstance { param($ClassName, $Filter); return $script:fakeService }
    Assert ($null -ne (Get-ManagedService)) 'managed service accepted'
    $script:fakeService.StartName = 'LocalSystem'
    $rejected = $false
    try { Get-ManagedService } catch { $rejected = $true }
    Assert $rejected 'unmanaged service refused'
    $script:fakeService.StartName = 'NT AUTHORITY\LocalService'
    function Assert-Administrator { }
    $script:calls = @()
    function Set-Service { param($Name, $StartupType); $script:calls += "startup:$StartupType" }
    function Invoke-Checked { param($File, $Arguments); $script:calls += "$File $($Arguments -join ' ')" }
    function Start-Service { param($Name); $script:calls += 'start' }
    function Stop-Service { param($Name); $script:calls += 'stop' }
    function Get-Service {
        param($Name)
        $controller = [pscustomobject]@{ Status = 'Running' }
        $controller | Add-Member ScriptMethod WaitForStatus { param($Status, $Timeout) }
        $controller | Add-Member ScriptMethod Refresh { }
        return $controller
    }
    [IO.File]::WriteAllText((Join-Path $stateDir 'address'), ('tc' + ('A' * 100)))
    Start-TailcatService | Out-Null
    Assert ($script:calls -contains 'startup:Automatic') 'start enables automatic boot startup'
    Assert ($script:calls -contains 'start') 'start launches service immediately'
    Assert (($script:calls -join ' ') -match 'restart/5000') 'host crash recovery configured'
    $Action = 'stop'
    Main | Out-Null
    Assert ($script:calls -contains 'startup:Disabled') 'stop disables boot startup'
    Assert ($script:calls -contains 'stop') 'stop stops service'
    Assert (!(Test-Path (Join-Path $stateDir 'address'))) 'stop clears stale address'
    $script:fakeService = $null
    function Install-Tailcat { }
    function New-Service {
        param($Name, $BinaryPathName, $DisplayName, $StartupType, $Credential, $Description)
        Assert ($StartupType -eq 'Automatic') 'new service starts at boot'
        Assert ($Credential.UserName -eq 'NT AUTHORITY\LocalService') 'new service uses limited account'
        Assert ($BinaryPathName -eq ('"' + $hostExe + '"')) 'service executable path quoted'
        $script:calls += 'install'
    }
    [IO.File]::WriteAllText((Join-Path $stateDir 'address'), ('tc' + ('A' * 100)))
    Start-TailcatService | Out-Null
    Assert ($script:calls -contains 'install') 'first installation registers service'
    Remove-Item -LiteralPath (Join-Path $stateDir 'address')
    Write-Output 'PASS: Windows host compilation, live address, child restart, key reuse, crash cleanup, service ownership, installation, automatic startup, stop'

    if ($TailcatBinary) {
        # Optional network smoke test using a real Windows binary, in an isolated profile.
        Copy-Item -LiteralPath $TailcatBinary -Destination (Join-Path $testDir 'tailcat.exe') -Force
        Remove-Item -LiteralPath (Join-Path $testState 'config\tailcat\keys\default.private.json')
        $hostProcess = Start-Process -FilePath $testHost -ArgumentList '--console' -WindowStyle Hidden -PassThru
        Wait-Until { Test-Path (Join-Path $testState 'address') } 'real Tailcat listening'
        Assert (Test-Path (Join-Path $testState 'config\tailcat\keys\default.private.json')) 'real Tailcat uses isolated service profile'
        Write-Output 'PASS: real Windows Tailcat starts and creates its isolated saved key'
    }
}
finally {
    if ($hostProcess -and !$hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force; $hostProcess.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($testDir)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
