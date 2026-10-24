param([switch]$HelpersOnly)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexChatWallpaper'
. (Join-Path $toolRoot 'windows-process.ps1')

function Stop-OwnedWallpaperHelper {
  param([string]$RecordPath, [string]$ExpectedScript, [string]$Role)
  if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) { return }
  $record = $null
  try { $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json } catch {}
  if (Test-WallpaperRecordedProcess -Record $record -ExpectedScript $ExpectedScript -Role $Role) {
    try { Stop-Process -Id ([int]$record.pid) -ErrorAction Stop }
    catch { throw ('Cannot stop the existing wallpaper ' + $Role + '. Run the installer from your normal Windows session, or sign out and sign in. Codex was not closed. Details: ' + $_.Exception.Message) }
  }
  Remove-Item -LiteralPath $RecordPath -Force
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\CodexChatWallpaper-WatcherStart')
$ownsMutex = $false
try {
  try { $ownsMutex = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
  if (-not $ownsMutex) { throw 'Wallpaper startup is busy. Try stopping again shortly.' }
  if (Test-Path -LiteralPath $stateRoot -PathType Container) {
    Set-Content -LiteralPath (Join-Path $stateRoot 'monitor-stop.request') -Value 'stop' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $stateRoot 'watcher-stop.request') -Value 'stop' -Encoding ASCII
    # Let a short relay finish rather than stop between closing a fresh app and
    # launching its replacement. This never terminates a Codex process.
    $monitorPath = Join-Path $stateRoot 'monitor.json'
    $deadline = [datetime]::UtcNow.AddSeconds(3)
    do {
      $record = $null
      try { $record = Get-Content -LiteralPath $monitorPath -Raw | ConvertFrom-Json } catch {}
      if (-not (Test-WallpaperRecordedProcess -Record $record -ExpectedScript (Join-Path $toolRoot 'follow-codex.ps1') -Role monitor)) { break }
      Start-Sleep -Milliseconds 150
    } while ([datetime]::UtcNow -lt $deadline)
    Stop-OwnedWallpaperHelper -RecordPath $monitorPath -ExpectedScript (Join-Path $toolRoot 'follow-codex.ps1') -Role monitor
    $watcherPath = Join-Path $stateRoot 'watcher.json'
    $deadline = [datetime]::UtcNow.AddSeconds(2)
    do {
      $record = $null
      try { $record = Get-Content -LiteralPath $watcherPath -Raw | ConvertFrom-Json } catch {}
      if (-not (Test-WallpaperRecordedProcess -Record $record -ExpectedScript (Join-Path $toolRoot 'wallpaper.mjs') -Role watcher)) { break }
      Start-Sleep -Milliseconds 150
    } while ([datetime]::UtcNow -lt $deadline)
    Stop-OwnedWallpaperHelper -RecordPath (Join-Path $stateRoot 'watcher.json') -ExpectedScript (Join-Path $toolRoot 'wallpaper.mjs') -Role watcher
  }
} finally {
  if ($ownsMutex) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
if (-not $HelpersOnly) {
  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  $node = if ($nodeCommand) { $nodeCommand.Source } else { Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' }
  try {
    & $node (Join-Path $toolRoot 'wallpaper.mjs') --remove
    if ($LASTEXITCODE -ne 0) { Write-Warning 'The current wallpaper will disappear when Codex closes.' }
  } catch { Write-Warning 'Codex is not reachable. The current wallpaper will disappear when Codex closes.' }
}
Write-Host 'Wallpaper startup connection and watcher stopped. Codex remains open.'
