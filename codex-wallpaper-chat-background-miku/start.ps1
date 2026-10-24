param([switch]$NoLaunch, [switch]$Shortcut)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexChatWallpaper'
$profile = Join-Path $stateRoot 'profile'
$port = 9335
$script:consoleShown = -not $Shortcut
. (Join-Path $toolRoot 'windows-process.ps1')

function Show-LauncherConsole {
  if ($script:consoleShown) { return }
  if (-not ('CodexWallpaperConsole' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexWallpaperConsole {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr handle, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
}
'@
  }
  $handle = [CodexWallpaperConsole]::GetConsoleWindow()
  if ($handle -ne [IntPtr]::Zero) {
    [void][CodexWallpaperConsole]::ShowWindow($handle, 5)
    [void][CodexWallpaperConsole]::SetForegroundWindow($handle)
  }
  $script:consoleShown = $true
}

function Get-NodePath {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
  if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
  throw 'Node.js 22+ was not found. Install Node.js, then run start.ps1 again.'
}

function Get-CodexExe {
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
  if ($package) {
    $exe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
  }
  $official = '^' + [regex]::Escape((Join-Path $env:ProgramFiles 'WindowsApps')) + '\\OpenAI\.Codex_\d+\.\d+\.\d+\.\d+_(?:x64|arm64|x86)__2p2nqsd0c76g0\\app\\ChatGPT\.exe$'
  foreach ($running in @(Get-OfficialCodexProcessRecords)) {
    try {
      if ($running.Executable -match $official -and (Test-Path -LiteralPath $running.Executable -PathType Leaf)) { return $running.Executable }
    } catch {}
  }
  $known = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1016.8622.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
  if (Test-Path -LiteralPath $known -PathType Leaf) { return $known }
  throw 'OpenAI.Codex is not installed or could not be located.'
}

function Test-Cdp {
  try {
    $reply = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 2
    return [bool]$reply.webSocketDebuggerUrl
  } catch { return $false }
}

function Get-VerifiedCodexProcesses {
  param([Parameter(Mandatory = $true)][string]$Executable)
  @(Get-OfficialCodexProcessRecords | Where-Object { $_.Executable -ieq $Executable })
}

function Close-VerifiedCodexProcesses {
  param([Parameter(Mandatory = $true)][string]$Executable)
  $running = @(Get-VerifiedCodexProcesses -Executable $Executable)
  if ($running.Count -eq 0) { return }
  Show-LauncherConsole
  Write-Host ('Codex processes still running: ' + (($running | Select-Object -ExpandProperty Id) -join ', '))
  Write-Host ('Verified executable: ' + $Executable)
  Write-Host 'Save any unsent input before continuing.'
  $answer = Read-Host 'Close these Codex processes and continue? [Y/N]'
  if ($answer -notmatch '^(y|yes)$') { throw 'Cancelled. No Codex process was closed.' }
  foreach ($item in $running) {
    try {
      $identity = Get-WallpaperProcessIdentity -ProcessId $item.Id
      if ($identity -and $identity.StartedTicks -eq $item.StartedTicks -and $identity.Executable -ieq $Executable) {
        $process = Get-Process -Id $item.Id -ErrorAction SilentlyContinue
        if ($process) { [void]$process.CloseMainWindow() }
      }
    } catch {}
  }
  $deadline = (Get-Date).AddSeconds(12)
  do {
    $remaining = @(Get-VerifiedCodexProcesses -Executable $Executable)
    if ($remaining.Count -eq 0) { return }
    Start-Sleep -Milliseconds 400
  } while ((Get-Date) -lt $deadline)
  $answer = Read-Host 'Codex background processes remain. Force-close their process trees? [Y/N]'
  if ($answer -notmatch '^(y|yes)$') { throw 'Cancelled. Close Codex from its tray menu and try again.' }
  foreach ($item in $remaining) {
    $current = Get-Process -Id $item.Id -ErrorAction SilentlyContinue
    $identity = Get-WallpaperProcessIdentity -ProcessId $item.Id
    if ($current -and $identity -and $identity.Executable -ieq $Executable -and $identity.StartedTicks -eq $item.StartedTicks) {
      # Closing one Electron parent can already remove the remaining children.
      # Do not emit a misleading error when a child exits during this loop.
      $previousPreference = $ErrorActionPreference
      try {
        $ErrorActionPreference = 'Continue'
        & taskkill.exe /PID $current.Id /T /F 2>$null | Out-Null
      } finally { $ErrorActionPreference = $previousPreference }
    }
  }
  Start-Sleep -Milliseconds 700
  if (@(Get-VerifiedCodexProcesses -Executable $Executable).Count -gt 0) {
    throw 'Verified Codex processes are still running. Startup was cancelled.'
  }
}

function Assert-CdpOwner {
  Assert-WallpaperCdpOwner -Port $port -ExpectedExecutable (Get-CodexExe)
}

try {
$node = Get-NodePath
$versionText = & $node --version
if ([int]($versionText -replace '^v(\d+).*$', '$1') -lt 22) {
  throw "Node.js 22+ is required; found $versionText"
}
$mp4s = @(Get-ChildItem -LiteralPath (Join-Path $toolRoot 'wallpapers') -Filter '*.mp4' -File)
if ($mp4s.Count -eq 0) { throw 'Put at least one MP4 in the wallpapers folder.' }
New-Item -ItemType Directory -Path $stateRoot,$profile -Force | Out-Null

if (-not (Test-Cdp)) {
  if ($NoLaunch) { throw 'Codex is not running with local CDP enabled.' }
  $exe = Get-CodexExe
  Close-VerifiedCodexProcesses -Executable $exe
  $argsLine = "--remote-debugging-port=$port --remote-debugging-address=127.0.0.1 --user-data-dir=`"$profile`""
  Start-Process -FilePath $exe -ArgumentList $argsLine
  $ready = $false
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Cdp) { $ready = $true; break }
  }
  if (-not $ready) {
    throw 'Codex launched, but its local CDP port did not open. Close Codex and see README.md.'
  }
}
Assert-CdpOwner

$controller = Join-Path $toolRoot 'wallpaper.mjs'
if (& (Join-Path $toolRoot 'watcher-start.ps1') -CheckOnly) {
  Write-Host 'Codex is ready; the existing wallpaper watcher will attach automatically.'
} else {
  Write-Host 'Waiting for the Codex chat page (up to 60 seconds)...'
  & $node $controller --once
  if ($LASTEXITCODE -ne 0) { throw 'Wallpaper injection failed. See the error above.' }
  & (Join-Path $toolRoot 'watcher-start.ps1')
}
Write-Host "Codex chat wallpaper started. Playlist: $($mp4s.Count) MP4 file(s)."
Write-Host 'To restore the original appearance, run stop.ps1.'
} catch {
  if (-not $Shortcut) { throw }
  Show-LauncherConsole
  Write-Host $_.Exception.Message -ForegroundColor Red
  [void](Read-Host 'Press Enter to close')
  exit 1
}
if ($Shortcut -and $script:consoleShown) { [void](Read-Host 'Press Enter to close') }
