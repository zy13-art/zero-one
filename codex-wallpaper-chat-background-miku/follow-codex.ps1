param([switch]$FunctionsOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-process.ps1')

function New-CodexFollowState {
  param([object[]]$InitialRecords = @())
  @{ Mode = $(if (@($InitialRecords).Count) { 'baseline' } else { 'armed' }); Candidate = $null; ProbeAt = [datetime]::MinValue; RelayUntil = [datetime]::MinValue }
}

function Test-CodexSameIdentity {
  param($Left, $Right)
  return $Left -and $Right -and $Left.Id -eq $Right.Id -and $Left.StartedTicks -eq $Right.StartedTicks -and $Left.Executable -ieq $Right.Executable
}

function Test-CodexRelayBatch {
  param($Candidate, [object[]]$Records, [datetime]$Now = [datetime]::UtcNow)
  if (-not $Candidate -or -not $Candidate.Arguments -or -not (Test-OfficialCodexPath $Candidate.Executable)) { return $false }
  if (-not @($Records | Where-Object { Test-CodexSameIdentity $_ $Candidate }).Count) { return $false }
  foreach ($record in @($Records)) {
    $age = ($Now.ToUniversalTime() - $record.Started.ToUniversalTime()).TotalSeconds
    if ($record.Executable -ine $Candidate.Executable -or $age -lt 0 -or $age -gt 10 -or $record.StartedTicks -lt $Candidate.StartedTicks) { return $false }
  }
  return $true
}

function Get-CodexFollowDecision {
  param([hashtable]$State, [object[]]$Records = @(), [bool]$CdpReady = $false, [datetime]$Now = [datetime]::UtcNow)
  $nowUtc = $Now.ToUniversalTime()
  if (-not @($Records).Count) {
    if ($State.Mode -eq 'relayed' -and $nowUtc -lt $State.RelayUntil) { return 'wait' }
    $State.Mode = 'armed'; $State.Candidate = $null
    return 'wait'
  }
  if ($CdpReady) { $State.Mode = 'active'; return 'wait' }
  if ($State.Mode -in @('baseline','active','blocked')) { return 'wait' }
  if ($State.Mode -eq 'relayed') { $State.Mode = 'active'; return 'wait' }
  if ($State.Mode -eq 'armed') {
    $main = @($Records | Where-Object { $_.Arguments -and -not @($_.Arguments | Where-Object { $_ -match '^--type(?:=|$)' }).Count } | Sort-Object StartedTicks | Select-Object -First 1)
    if (-not $main.Count) { $State.Mode = 'blocked'; return 'skip-arguments' }
    $candidate = $main[0]
    if (-not (Test-CodexRelayBatch -Candidate $candidate -Records $Records -Now $nowUtc)) { $State.Mode = 'blocked'; return 'skip-age-or-identity' }
    $State.Candidate = $candidate; $State.ProbeAt = $nowUtc; $State.Mode = 'probing'
    return 'probe'
  }
  if ($State.Mode -eq 'probing') {
    if (-not (Test-CodexRelayBatch -Candidate $State.Candidate -Records $Records -Now $nowUtc)) { $State.Mode = 'blocked'; return 'skip-age-or-identity' }
    if (($nowUtc - $State.ProbeAt).TotalSeconds -lt 1.5) { return 'wait' }
    # Mark before any OS action: failure must never cause a restart loop.
    $State.Mode = 'relayed'; $State.RelayUntil = $nowUtc.AddSeconds(10)
    return 'relay'
  }
  return 'wait'
}

function Test-FollowCodexCdp {
  try {
    Assert-WallpaperCdpOwner -Port 9335
    $reply = Invoke-RestMethod -Uri 'http://127.0.0.1:9335/json/version' -TimeoutSec 1
    return [bool]$reply.webSocketDebuggerUrl
  } catch { return $false }
}

function Invoke-CodexStartupRelay {
  param($Candidate, [string]$Profile)
  $current = @(Get-OfficialCodexProcessRecords)
  if (-not (Test-CodexRelayBatch -Candidate $Candidate -Records $current)) { throw 'New Codex launch no longer matches the fresh verified batch.' }
  $arguments = @(Get-WallpaperRelayArguments -OriginalArguments $Candidate.Arguments -Profile $Profile)
  # Obtain the complete launch command before closing anything. If it cannot be
  # read, Get-WallpaperRelayArguments throws and the existing app stays open.
  foreach ($record in $current) {
    $again = Get-WallpaperProcessIdentity -ProcessId $record.Id
    if (Test-CodexSameIdentity $record $again) {
      $process = Get-Process -Id $record.Id -ErrorAction SilentlyContinue
      if ($process) { try { [void]$process.CloseMainWindow() } finally { $process.Dispose() } }
    }
  }
  Start-Sleep -Milliseconds 500
  $remaining = @(Get-OfficialCodexProcessRecords)
  if ($remaining.Count -and -not (Test-CodexRelayBatch -Candidate $Candidate -Records $remaining)) {
    # The main window may already have exited. Only the original captured
    # identities can be terminated; newly reused PIDs or older sessions stay.
    foreach ($item in $remaining) {
      if (-not @($current | Where-Object { Test-CodexSameIdentity $_ $item }).Count) { throw 'Codex process identities changed during startup relay.' }
    }
  }
  foreach ($record in $remaining) {
    if (-not @($current | Where-Object { Test-CodexSameIdentity $_ $record }).Count) { throw 'Unexpected Codex process appeared during startup relay.' }
    if (([datetime]::UtcNow - $record.Started.ToUniversalTime()).TotalSeconds -gt 10) { throw 'Codex launch is no longer fresh; leaving remaining processes alone.' }
    $again = Get-WallpaperProcessIdentity -ProcessId $record.Id
    if (Test-CodexSameIdentity $record $again) { Stop-Process -Id $record.Id -ErrorAction Stop }
  }
  if (@(Get-OfficialCodexProcessRecords).Count) { throw 'Codex is still running; startup relay was cancelled.' }
  New-Item -ItemType Directory -Path $Profile -Force | Out-Null
  # This is the interactive app the user just opened, so show its normal window.
  Start-Process -FilePath $Candidate.Executable -ArgumentList (ConvertTo-WallpaperArgumentString $arguments) -WindowStyle Normal | Out-Null
}

function Write-CodexFollowLog {
  param([string]$Message)
  Add-Content -LiteralPath $script:followLog -Value (([datetime]::UtcNow.ToString('o')) + ' ' + $Message) -Encoding UTF8
}

if ($FunctionsOnly) { return }
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexChatWallpaper'
$script:followLog = Join-Path $stateRoot 'follow-codex.log'
$stopRequest = Join-Path $stateRoot 'monitor-stop.request'
$mutex = New-Object System.Threading.Mutex($false, 'Local\CodexChatWallpaper-FollowCodex')
$ownsMutex = $false
try {
  try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
  if (-not $ownsMutex) { return }
  New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
  $initial = @(Get-OfficialCodexProcessRecords)
  $state = New-CodexFollowState -InitialRecords $initial
  Write-CodexFollowLog ('Startup connection ready; existing Codex sessions preserved: ' + $initial.Count)
  $lastError = $null
  while (-not (Test-Path -LiteralPath $stopRequest -PathType Leaf)) {
    try {
      $records = @(Get-OfficialCodexProcessRecords)
      $ready = $false
      if ($records.Count -and $state.Mode -notin @('baseline','active','blocked')) { $ready = Test-FollowCodexCdp }
      $decision = Get-CodexFollowDecision -State $state -Records $records -CdpReady $ready
      if ($decision -eq 'relay') {
        Write-CodexFollowLog 'New ordinary Codex launch detected; enabling wallpaper startup.'
        Invoke-CodexStartupRelay -Candidate $state.Candidate -Profile (Join-Path $stateRoot 'profile')
      } elseif ($decision -like 'skip-*') {
        Write-CodexFollowLog ('Left Codex open without relaunch: ' + $decision)
      }
      $lastError = $null
    } catch {
      $state.Mode = 'blocked'
      if ($_.Exception.Message -ne $lastError) { Write-CodexFollowLog $_.Exception.Message }
      $lastError = $_.Exception.Message
    }
    Start-Sleep -Milliseconds 400
  }
} finally {
  if ($ownsMutex) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
