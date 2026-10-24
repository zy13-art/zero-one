$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$script:passed = 0
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Assert-Throws([scriptblock]$Action, [string]$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Assert-True $failed $Message }
function Import-Functions([string]$Name) {
  $tokens=$null; $errors=$null
  $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot $Name),[ref]$tokens,[ref]$errors)
  Assert-True ($errors.Count -eq 0) ('Syntax: ' + $Name)
  foreach ($definition in $ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] },$false)) {
    . ([scriptblock]::Create(($definition.Extent.Text -replace '^function ([\w-]+)','function script:$1')))
  }
}
foreach ($file in Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1') {
  $tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
  Assert-True ($errors.Count -eq 0) ('All scripts parse: ' + $file.Name)
}
. (Join-Path $scriptsRoot 'windows-process.ps1')
$self=Get-WallpaperProcessIdentity -ProcessId $PID
Assert-True ($self -and $self.Id -eq $PID -and $self.StartedTicks -gt 0 -and $self.Executable) 'Limited-information API reads this exact process identity'
Assert-True ([bool]$self.Arguments) 'Original process arguments can be read without CIM'
Assert-True ($self.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId) 'Process records identify the current Windows session'
foreach ($arguments in @(
  ,@('program.exe','simple','codex://threads/abc?view=review')
  ,@('program.exe','C:\path with spaces\','a"quoted"value','')
  ,@('program.exe','three\\\"quotes','trailing\\','C:\space and slash\\')
)) {
  $encoded=ConvertTo-WallpaperArgumentString $arguments
  $decoded=[CodexWallpaperWindowsProcess]::ParseArguments($encoded)
  Assert-True (($decoded | ConvertTo-Json -Compress) -ceq ($arguments | ConvertTo-Json -Compress)) 'Windows argument parser preserves spaces, quotes, trailing slashes and empty arguments'
}
$official=Join-Path $env:ProgramFiles 'WindowsApps\OpenAI.Codex_26.1016.8622.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
Assert-True (Test-OfficialCodexPath $official) 'Official package executable is accepted'
Assert-True (-not (Test-OfficialCodexPath 'C:\Other\ChatGPT.exe')) 'A same-name executable outside WindowsApps is rejected'
Assert-True (-not (Test-OfficialCodexPath ($official -replace '2p2nqsd0c76g0','anotherpublisher'))) 'Another package publisher is rejected'
$relay=@(Get-WallpaperRelayArguments -OriginalArguments @($official,'codex://threads/a?x=1','--user-data-dir','C:\Old','--remote-debugging-port=9000','--remote-debugging-address','0.0.0.0','--custom','a b') -Profile 'C:\A B\profile')
Assert-True ($relay.Count -eq 6 -and $relay[0] -ceq 'codex://threads/a?x=1' -and $relay[1] -eq '--custom' -and $relay[2] -eq 'a b') 'Original deep link and application arguments are forwarded in order'
Assert-True ($relay -contains '--remote-debugging-port=9335' -and $relay -contains '--remote-debugging-address=127.0.0.1' -and $relay -contains '--user-data-dir=C:\A B\profile') 'Dedicated profile and loopback switches remain separate arguments'
Assert-True (-not ($relay -contains 'C:\Old') -and -not ($relay -contains '0.0.0.0')) 'Old debug/profile values are replaced'
Assert-Throws { Get-WallpaperRelayArguments -OriginalArguments $null -Profile 'C:\P' } 'Unreadable original command line is never silently discarded'
$bare=@(Get-WallpaperRelayArguments -OriginalArguments @($official,'--remote-debugging-port','--custom','codex://threads/b') -Profile 'C:\P')
Assert-True ($bare -contains '--custom' -and $bare -contains 'codex://threads/b') 'A malformed bare debug switch cannot swallow a following application switch or deep link'

$now=[datetime]'2026-10-24T12:00:00Z'
function New-TestIdentity([int]$Number, [double]$Age, [string]$Exe=$official, [string[]]$Arguments=@($official)) {
  $started=$now.AddSeconds(-$Age).ToUniversalTime()
  [pscustomobject]@{ Id=$Number; Executable=$Exe; Started=$started; StartedTicks=$started.Ticks; Arguments=$Arguments }
}
$script:actualIdentity=New-TestIdentity 1234 1
function Get-WallpaperProcessIdentity { param($ProcessId) if ($script:identityMap) { return $script:identityMap[[int]$ProcessId] }; $script:actualIdentity }
$script:listeners=@([pscustomobject]@{ Address='127.0.0.1'; ProcessId=1234 })
function Get-WallpaperTcpListeners { param($Port) $script:listeners }
Assert-WallpaperCdpOwner; Assert-True $true 'A loopback listener owned by official Codex is accepted'
$script:listeners += [pscustomobject]@{ Address='[::1]'; ProcessId=1234 }
Assert-WallpaperCdpOwner; Assert-True $true 'IPv4 and IPv6 loopback owned by the same official process are accepted'
$script:listeners=@([pscustomobject]@{ Address='0.0.0.0'; ProcessId=1234 })
Assert-Throws { Assert-WallpaperCdpOwner } 'A non-loopback listener is rejected'
$script:listeners=@([pscustomobject]@{ Address='127.0.0.1'; ProcessId=1234 },[pscustomobject]@{ Address='[::1]'; ProcessId=5678 })
Assert-Throws { Assert-WallpaperCdpOwner } 'Different owners on the same debug port are rejected'
$script:listeners=@()
Assert-Throws { Assert-WallpaperCdpOwner } 'A missing listener is rejected'
$script:listeners=@([pscustomobject]@{ Address='127.0.0.1'; ProcessId=1234 })
$script:actualIdentity=New-TestIdentity 1234 1 'C:\Other\ChatGPT.exe'
Assert-Throws { Assert-WallpaperCdpOwner } 'A different app cannot impersonate the CDP endpoint'
$script:actualIdentity=New-TestIdentity 1234 1
Assert-Throws { Assert-WallpaperCdpOwner -ExpectedExecutable 'C:\Different\ChatGPT.exe' } 'A mismatched expected installation is rejected'

$expectedScript='C:\Helper\wallpaper.mjs'
$script:actualIdentity=New-TestIdentity 1234 1 'C:\Node\node.exe' @('C:\Node\node.exe',$expectedScript,'--watch')
$record=[pscustomobject]@{ pid=1234; started=$script:actualIdentity.Started.ToString('o'); executable='C:\Node\node.exe'; controller=$expectedScript }
Assert-True (Test-WallpaperRecordedProcess $record $expectedScript watcher) 'An exact owned watcher record matches'
$record.started=$script:actualIdentity.Started
Assert-True (Test-WallpaperRecordedProcess $record $expectedScript watcher) 'PowerShell 7 JSON DateTime preserves precise process creation time'
$record.started=$script:actualIdentity.Started.AddTicks(1)
Assert-True (-not (Test-WallpaperRecordedProcess $record $expectedScript watcher)) 'Even a one-tick PID creation mismatch is rejected'
$record.started=$script:actualIdentity.Started
$record.controller='C:\Other\wallpaper.mjs'
Assert-True (-not (Test-WallpaperRecordedProcess $record $expectedScript watcher)) 'A different helper script is never treated as owned'
$record.controller=$expectedScript
$script:actualIdentity.Arguments=@('C:\Node\node.exe','C:\Other\app.mjs','--watch')
Assert-True (-not (Test-WallpaperRecordedProcess $record $expectedScript watcher)) 'Runtime arguments must contain the exact recorded script'
$script:actualIdentity.Executable='C:\Node\other.exe'
Assert-True (-not (Test-WallpaperRecordedProcess $record $expectedScript watcher)) 'A different executable at the PID is rejected'

Import-Functions 'follow-codex.ps1'
$main=New-TestIdentity 2000 1 $official @($official,'codex://threads/a')
$child=New-TestIdentity 2001 0.9 $official @($official,'--type=renderer')
$batch=@($main,$child)
$state=New-CodexFollowState -InitialRecords $batch
Assert-True ($state.Mode -eq 'baseline') 'Existing Codex sessions become a protected baseline'
Assert-True ((Get-CodexFollowDecision $state $batch $false $now.AddSeconds(3)) -eq 'wait' -and $state.Mode -eq 'baseline') 'A baseline session is never automatically relaunched'
$newChild=New-TestIdentity 2002 0.2 $official @($official,'--type=utility')
Assert-True ((Get-CodexFollowDecision $state (@($batch)+@($newChild)) $false $now) -eq 'wait' -and $state.Mode -eq 'baseline') 'New renderer helpers cannot trigger relaunch of an existing session'
[void](Get-CodexFollowDecision $state @() $false $now)
Assert-True ($state.Mode -eq 'armed') 'Only a complete Codex exit arms ordinary-start detection'
Assert-True ((Get-CodexFollowDecision $state $batch $false $now) -eq 'probe') 'A fresh ordinary main process enters the CDP grace period'
Assert-True ((Get-CodexFollowDecision $state $batch $false $now.AddSeconds(1)) -eq 'wait') 'The grace period does not prematurely close the new app'
Assert-True ((Get-CodexFollowDecision $state $batch $false $now.AddSeconds(1.6)) -eq 'relay' -and $state.Mode -eq 'relayed') 'A fresh app without CDP requests exactly one relay'
Assert-True ((Get-CodexFollowDecision $state $batch $false $now.AddSeconds(2)) -eq 'wait') 'Failure or delayed CDP cannot repeat a relay on the same session'
Assert-True ((Get-CodexFollowDecision $state $batch $false $now.AddSeconds(20)) -eq 'wait') 'The same failed session remains untouched even after the freshness window'
$state=New-CodexFollowState
[void](Get-CodexFollowDecision $state $batch $false $now)
Assert-True ((Get-CodexFollowDecision $state $batch $true $now.AddSeconds(1)) -eq 'wait' -and $state.Mode -eq 'active') 'An already debug-enabled launch is used directly without relaunch'
$state=New-CodexFollowState
$old=New-TestIdentity 3000 15
Assert-True ((Get-CodexFollowDecision $state @($old) $false $now) -eq 'skip-age-or-identity') 'An older instance is left open'
$state=New-CodexFollowState
$unknown=New-TestIdentity 3001 1 $official $null
Assert-True ((Get-CodexFollowDecision $state @($unknown) $false $now) -eq 'skip-arguments') 'Unreadable activation arguments leave the original app open'
$state=New-CodexFollowState
Assert-True ((Get-CodexFollowDecision $state @($child) $false $now) -eq 'skip-arguments') 'A renderer process alone is never selected as the application main process'
$state=New-CodexFollowState
[void](Get-CodexFollowDecision $state $batch $false $now)
$reused=New-TestIdentity 2000 0.1
Assert-True ((Get-CodexFollowDecision $state @($reused,$child) $false $now.AddSeconds(2)) -eq 'skip-age-or-identity') 'Reusing a candidate PID cannot close a replacement process'
$state=New-CodexFollowState
[void](Get-CodexFollowDecision $state $batch $false $now)
Assert-True ((Get-CodexFollowDecision $state $batch $false $now.AddSeconds(12)) -eq 'skip-age-or-identity') 'A delayed probe cannot close an app that has become older than ten seconds'
$state=New-CodexFollowState
[void](Get-CodexFollowDecision $state $batch $false $now)
[void](Get-CodexFollowDecision $state $batch $false $now.AddSeconds(2))
[void](Get-CodexFollowDecision $state @() $false $now.AddSeconds(2.1))
Assert-True ($state.Mode -eq 'relayed') 'The empty handoff interval cannot re-arm the monitor and cause a loop'
[void](Get-CodexFollowDecision $state $batch $false $now.AddSeconds(2.2))
[void](Get-CodexFollowDecision $state @() $false $now.AddSeconds(3))
Assert-True ($state.Mode -eq 'armed') 'After a completed session exits, the next deliberate ordinary launch can be detected'

# All process mutation APIs are mocked from here. No Codex/helper is launched or stopped.
$script:live=@(); $script:identityMap=@{}; $script:closed=@(); $script:stopped=@(); $script:launched=@(); $script:created=0
function Get-OfficialCodexProcessRecords { $script:live }
function Get-Process {
  param($Id,$ErrorAction)
  $item=[pscustomobject]@{ Id=$Id }; $item | Add-Member ScriptMethod CloseMainWindow { $script:closed += $this.Id; return $true }; $item | Add-Member ScriptMethod Dispose {}; $item
}
function Stop-Process { param($Id,$ErrorAction) $script:stopped += $Id; $script:live=@($script:live | Where-Object { $_.Id -ne $Id }) }
function Start-Process { param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError) $script:launched += [pscustomobject]@{ FilePath=$FilePath; Arguments=$ArgumentList; WindowStyle=$WindowStyle }; [pscustomobject]@{ Id=4321 } }
function Start-Sleep { param($Milliseconds) }
function New-Item { param($ItemType,$Path,[switch]$Force) $script:created++ }
$freshNow=[datetime]::UtcNow
$main.Started=$freshNow.AddSeconds(-1); $main.StartedTicks=$main.Started.Ticks
$child.Started=$freshNow.AddSeconds(-0.9); $child.StartedTicks=$child.Started.Ticks
$script:live=@($main,$child); $script:identityMap=@{ 2000=$main; 2001=$child }
Invoke-CodexStartupRelay -Candidate $main -Profile 'C:\Profile With Spaces'
Assert-True ($script:closed.Count -eq 2 -and $script:stopped.Count -eq 2 -and $script:launched.Count -eq 1) 'A relay only closes captured fresh identities and launches one replacement'
Assert-True ($script:launched[0].FilePath -ieq $official -and $script:launched[0].WindowStyle -eq 'Normal') 'The exact official interactive app is relaunched visibly'
$parsed=[CodexWallpaperWindowsProcess]::ParseArguments('program.exe ' + $script:launched[0].Arguments)
Assert-True ($parsed -contains 'codex://threads/a' -and $parsed -contains '--user-data-dir=C:\Profile With Spaces') 'The replacement command preserves its deep link and quoted dedicated profile'
$script:live=@($old); $script:closed=@(); $script:stopped=@(); $script:launched=@()
Assert-Throws { Invoke-CodexStartupRelay -Candidate $main -Profile 'C:\P' } 'An older or changed batch is rejected before closing anything'
Assert-True (-not $script:closed.Count -and -not $script:stopped.Count -and -not $script:launched.Count) 'Batch rejection performs no mutation'

Import-Functions 'stop.ps1'
$script:hasRecord=$true
$script:savedRecord=[pscustomobject]@{ pid=4321; started=$freshNow.ToString('o'); executable='C:\Node\node.exe'; controller=$expectedScript }
function Test-Path { param($LiteralPath,$PathType) $script:hasRecord }
function Get-Content { param($LiteralPath,[switch]$Raw) $script:savedRecord | ConvertTo-Json }
function Remove-Item { param($LiteralPath,[switch]$Force) $script:hasRecord=$false }
$script:identityMap=@{ 4321=[pscustomobject]@{ Id=4321; Executable='C:\Node\node.exe'; Started=$freshNow; StartedTicks=$freshNow.Ticks; Arguments=@('C:\Node\node.exe',$expectedScript,'--watch') } }
$script:stopped=@()
Stop-OwnedWallpaperHelper 'C:\State\watcher.json' $expectedScript watcher
Assert-True ($script:stopped.Count -eq 1 -and $script:stopped[0] -eq 4321) 'Stop targets only the exact owned helper identity'
$script:hasRecord=$true; $script:stopped=@(); $script:identityMap[4321].StartedTicks++
Stop-OwnedWallpaperHelper 'C:\State\watcher.json' $expectedScript watcher
Assert-True (-not $script:stopped.Count) 'A reused helper PID is never terminated'
$script:hasRecord=$true; $script:identityMap[4321].StartedTicks=$freshNow.Ticks; $script:identityMap[4321].Arguments=@('powershell.exe','-File','C:\Unrelated.ps1')
Stop-OwnedWallpaperHelper 'C:\State\watcher.json' $expectedScript watcher
Assert-True (-not $script:stopped.Count) 'An unrelated Node or PowerShell program is never terminated'
Write-Output ('PASS: ' + $script:passed + ' startup connection checks')
