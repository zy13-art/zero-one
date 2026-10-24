param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexChatWallpaper'
. (Join-Path $toolRoot 'windows-process.ps1')

function Test-WallpaperWatcherProcess {
  param($Record)
  Test-WallpaperRecordedProcess -Record $Record -ExpectedScript (Join-Path $toolRoot 'wallpaper.mjs') -Role watcher
}

function Get-WallpaperNodePath {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
  if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
  throw 'Node.js 22+ was not found. Install Node.js, then run watcher-start.ps1 again.'
}

function Get-WallpaperHelperRecord {
  param([string]$RecordPath, [string]$ExpectedScript, [string]$Role)
  try {
    if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) { return $null }
    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    if (Test-WallpaperRecordedProcess -Record $record -ExpectedScript $ExpectedScript -Role $Role) { return $record }
  } catch {}
  return $null
}

function Start-WallpaperHelper {
  param([string]$Executable, [string[]]$Arguments, [string]$Controller, [string]$Role, [string]$RecordPath, [string]$LogName)
  $start = @{ FilePath = $Executable; ArgumentList = (ConvertTo-WallpaperArgumentString $Arguments); WindowStyle = 'Hidden'; RedirectStandardOutput = (Join-Path $stateRoot ($LogName + '.log')); RedirectStandardError = (Join-Path $stateRoot ($LogName + '-error.log')); PassThru = $true }
  $process = Start-Process @start
  $identity = $null
  for ($attempt = 0; $attempt -lt 10 -and -not $identity; $attempt++) {
    $identity = Get-WallpaperProcessIdentity -ProcessId $process.Id
    if (-not $identity) { Start-Sleep -Milliseconds 100 }
  }
  if (-not $identity) { throw ('Could not identify newly started wallpaper ' + $Role) }
  $record = @{ pid = $identity.Id; started = $identity.Started.ToUniversalTime().ToString('o'); executable = $identity.Executable; controller = $Controller; role = $Role }
  if (-not (Test-WallpaperRecordedProcess -Record $record -ExpectedScript $Controller -Role $Role)) { throw ('New wallpaper helper identity did not match its launch: ' + $Role) }
  $record | ConvertTo-Json | Set-Content -LiteralPath $RecordPath -Encoding UTF8
}

function Invoke-WallpaperBackgroundStart {
  param([switch]$CheckOnly)
  $mutex = New-Object System.Threading.Mutex($false, 'Local\CodexChatWallpaper-WatcherStart')
  $ownsMutex = $false
  try {
    try { $ownsMutex = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another wallpaper launcher is still starting. Try again shortly.' }
    $controller = Join-Path $toolRoot 'wallpaper.mjs'
    $monitor = Join-Path $toolRoot 'follow-codex.ps1'
    $watcherPath = Join-Path $stateRoot 'watcher.json'
    $monitorPath = Join-Path $stateRoot 'monitor.json'
    $watcherRecord = Get-WallpaperHelperRecord -RecordPath $watcherPath -ExpectedScript $controller -Role watcher
    $monitorRecord = Get-WallpaperHelperRecord -RecordPath $monitorPath -ExpectedScript $monitor -Role monitor
    if ($CheckOnly) { return [bool]($watcherRecord -and $monitorRecord) }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    if (-not $watcherRecord) {
      $node = Get-WallpaperNodePath
      $version = & $node --version
      if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22) { throw "Node.js 22+ is required; found $version" }
      if (-not (Test-Path -LiteralPath $controller -PathType Leaf)) { throw "Missing wallpaper controller: $controller" }
      & $node $controller --validate | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'Wallpaper settings or MP4 playlist are invalid. Startup connection was not enabled.' }
      $watcherStop = Join-Path $stateRoot 'watcher-stop.request'
      if (Test-Path -LiteralPath $watcherStop -PathType Leaf) { Remove-Item -LiteralPath $watcherStop -Force }
      Start-WallpaperHelper -Executable $node -Arguments @($controller,'--watch') -Controller $controller -Role watcher -RecordPath $watcherPath -LogName watcher
    }
    if (-not $monitorRecord) {
      if (-not (Test-Path -LiteralPath $monitor -PathType Leaf)) { throw "Missing startup connection: $monitor" }
      $stopRequest = Join-Path $stateRoot 'monitor-stop.request'
      if (Test-Path -LiteralPath $stopRequest -PathType Leaf) { Remove-Item -LiteralPath $stopRequest -Force }
      $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
      Start-WallpaperHelper -Executable $powerShell -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$monitor) -Controller $monitor -Role monitor -RecordPath $monitorPath -LogName monitor
    }
    Write-Host 'Codex startup connection and wallpaper watcher are ready. Existing Codex sessions are preserved.'
  } finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

Invoke-WallpaperBackgroundStart -CheckOnly:$CheckOnly
