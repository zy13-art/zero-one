$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'follow-codex.ps1') -FunctionsOnly
$now=[datetime]::UtcNow
$exe=Join-Path $env:ProgramFiles 'WindowsApps\OpenAI.Codex_26.1021.3705.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
function New-Identity([int]$Number,[double]$Age,[string[]]$Arguments=@($exe)) {
  $started=$now.AddSeconds(-$Age)
  [pscustomobject]@{Id=$Number;Started=$started;StartedTicks=$started.Ticks;Executable=$exe;Arguments=$Arguments}
}
$old=New-Identity 100 60
$new=New-Identity 200 1
$child=New-Identity 201 .8 @($exe,'--type=renderer')
$state=New-CodexFollowState -InitialRecords @($old)
if((Get-CodexFollowDecision $state @($new,$child) $false $now) -ne 'probe'){throw 'A replacement main process must be detected without observing an empty process list.'}
if((Get-CodexFollowDecision $state @($new,$child) $false $now.AddSeconds(1.6)) -ne 'relay'){throw 'A fresh replacement main process must request one relay after its grace period.'}
if((Get-CodexFollowDecision $state @($new,$child) $false $now.AddSeconds(2)) -ne 'wait'){throw 'The same replacement session must never be relayed twice.'}
Write-Output 'PASS: a restart with no empty process snapshot is detected and relayed once.'
$oldChild=New-Identity 101 59 @($exe,'--type=crashpad-handler')
$state=New-CodexFollowState -InitialRecords @($old,$oldChild)
if((Get-CodexFollowDecision $state @($oldChild,$new,$child) $false $now) -ne 'wait' -or $state.Mode -ne 'armed'){throw 'An old child overlapping a new main must be left alone without blocking the replacement session.'}
if((Get-CodexFollowDecision $state @($new,$child) $false $now.AddMilliseconds(400)) -ne 'probe'){throw 'Once the old child exits, the fresh new session must still be detected.'}
if((Get-CodexFollowDecision $state @($new,$child) $false $now.AddSeconds(2)) -ne 'relay'){throw 'A short old-child overlap must not suppress the replacement relay.'}
Write-Output 'PASS: an old crashpad child can overlap a fresh launch without being terminated or blocking it.'
foreach($mode in @('baseline','active','blocked')) {
  $state=New-CodexFollowState -InitialRecords @($old);$state.Mode=$mode
  if((Get-CodexFollowDecision $state @($old,$new,$child) $false $now) -ne 'wait'){throw ('A still-running protected main must be preserved: '+$mode)}
  if((Get-CodexFollowDecision $state @($new,$child) $false $now) -ne 'probe'){throw ('A departed protected main must not suppress its replacement: '+$mode)}
}
Write-Output 'PASS: baseline, active and blocked states preserve live sessions and detect their replacement.'
$state=New-CodexFollowState -InitialRecords @($old)
if((Get-CodexFollowDecision $state @($new,$child) $true $now) -ne 'wait' -or $state.Mode -ne 'active'){throw 'A replacement that already exposes CDP must be reused directly.'}
$third=New-Identity 300 .2
if((Get-CodexFollowDecision $state @($third) $false $now) -ne 'probe'){throw 'An active session must track the new main identity rather than the original baseline.'}
$reused=New-Identity 100 .5
$state=New-CodexFollowState -InitialRecords @($old)
if((Get-CodexFollowDecision $state @($reused) $false $now) -ne 'probe'){throw 'A reused PID with a new creation time identifies a replacement session.'}
$late=New-Identity 400 25
$state=New-CodexFollowState -InitialRecords @($old)
if((Get-CodexFollowDecision $state @($late) $false $now) -ne 'skip-age-or-identity'){throw 'Replacement detection must retain the ten-second freshness limit.'}
Write-Output 'PASS: direct CDP reuse, PID creation times and the freshness limit remain enforced.'
