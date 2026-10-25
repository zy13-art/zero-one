$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'windows-process.ps1')
. (Join-Path $root 'follow-codex.ps1') -FunctionsOnly
$exe = Join-Path $env:ProgramFiles 'WindowsApps\OpenAI.Codex_26.1021.3705.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
$now = [datetime]::UtcNow
function New-Record([int]$Number,[int]$Parent,[string[]]$Arguments) {
  $started=$now.AddMilliseconds(-1000+$Number)
  [pscustomobject]@{ Id=$Number; ParentId=$Parent; Executable=$exe; Started=$started; StartedTicks=$started.Ticks; Arguments=$Arguments }
}
$main=New-Record 100 1 @($exe)
$child=New-Record 101 100 @($exe,'--type=renderer')
$late=New-Record 102 100 @($exe,'--type=utility')
$script:map=@{100=$main;101=$child;102=$late}
$script:live=@($main,$child);$script:stopped=@();$script:launched=0;$script:enumerations=0
function Get-WallpaperProcessIdentity { param($ProcessId) $script:map[[int]$ProcessId] }
function Get-OfficialCodexProcessRecords {
  $script:enumerations++
  if($script:enumerations -eq 2){$script:live+=,$late}
  $script:live
}
function Get-Process { param($Id,$ErrorAction) $p=[pscustomobject]@{Id=$Id};$p|Add-Member ScriptMethod CloseMainWindow {$true};$p|Add-Member ScriptMethod Dispose {};$p }
function Stop-Process { param($Id,$ErrorAction) $script:stopped+=,$Id;$script:live=@($script:live|Where-Object {$_.Id -ne $Id});$script:map.Remove([int]$Id) }
function Start-Process { param($FilePath,$ArgumentList,$WindowStyle) $script:launched++ }
function Start-Sleep { param($Milliseconds) }
function New-Item { param($Path,$ItemType,[switch]$Force) }
Invoke-CodexStartupRelay -Candidate $main -Profile 'C:\FixtureProfile'
if($script:launched -ne 1 -or $script:stopped.Count -ne 3 -or $script:stopped -notcontains 102){throw 'A verified late Electron child must not cancel startup relay.'}
Write-Output 'PASS: a late child of the captured fresh Codex process is included in its single relay.'
$captured=@($main,$child)
$script:map=@{100=$main;101=$child;102=$late}
foreach($kind in @('unrelated-parent','second-main','reused-parent')) {
  $unexpected=New-Record 103 999 @($exe,'--type=renderer')
  if($kind -eq 'second-main'){$unexpected.ParentId=100;$unexpected.Arguments=@($exe)}
  if($kind -eq 'reused-parent'){
    $unexpected.ParentId=100
    $replacement=New-Record 100 1 @($exe);$replacement.StartedTicks++
    $script:map[100]=$replacement
  }
  $rejected=$false
  try { Get-CodexVerifiedRelayRemainder -Candidate $main -Captured $captured -Records @($unexpected) | Out-Null } catch { $rejected=$true }
  if(-not $rejected){throw ('Unrelated or ambiguous process must be preserved: '+$kind)}
}
Write-Output 'PASS: unrelated descendants, a second main process and reused parent identities are rejected.'
foreach($mode in @('already-exited','access-denied')) {
  $script:live=@($main,$child);$script:map=@{100=$main;101=$child};$script:enumerations=10;$script:launched=0;$script:stopMode=$mode
  function Stop-Process {
    param($Id,$ErrorAction)
    if($script:stopMode -eq 'access-denied'){throw 'Access is denied'}
    $script:live=@($script:live|Where-Object {$_.Id -ne $Id});$script:map.Remove([int]$Id)
    if($Id -eq 101){throw 'Cannot find a process with the process identifier 101.'}
  }
  $failed=$false
  try { Invoke-CodexStartupRelay -Candidate $main -Profile 'C:\FixtureProfile' } catch {$failed=$true}
  if($mode -eq 'already-exited' -and ($failed -or $script:launched -ne 1)){throw 'A process that naturally exits before Stop-Process must not cancel relay.'}
  if($mode -eq 'access-denied' -and (-not $failed -or $script:launched)){throw 'An access denial for a still-live process must remain an error.'}
}
Write-Output 'PASS: natural child exit is tolerated, while access denial for a live process still blocks relay.'
