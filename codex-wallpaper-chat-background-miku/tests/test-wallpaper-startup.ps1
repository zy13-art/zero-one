$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$script:passed = 0
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Import-ScriptFunctions([string]$Path) {
  $tokens=$null; $errors=$null
  $ast=[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  Assert-True ($errors.Count -eq 0) ('PowerShell syntax: ' + $Path)
  foreach ($definition in $ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] },$false)) {
    . ([scriptblock]::Create(($definition.Extent.Text -replace '^function ([\w-]+)','function script:$1')))
  }
}
. (Join-Path $scriptsRoot 'windows-process.ps1')
Import-ScriptFunctions (Join-Path $scriptsRoot 'start.ps1')
Import-ScriptFunctions (Join-Path $scriptsRoot 'install-autostart.ps1')
Import-ScriptFunctions (Join-Path $scriptsRoot 'uninstall-autostart.ps1')
Import-ScriptFunctions (Join-Path $scriptsRoot 'watcher-start.ps1')
$toolRoot=$scriptsRoot
$stateRoot='C:\State\CodexChatWallpaper'
$shortcutName = 'Codex ' + [char]0x52a8 + [char]0x6001 + [char]0x58c1 + [char]0x7eb8 + '.lnk'
$specs = @(Get-WallpaperShortcutSpecs -Desktop 'C:\Desktop' -Programs 'C:\Programs' -Startup 'C:\Startup')
Assert-True ($specs.Count -eq 0) 'Default shortcut specification creates no redundant manual icons'
$specs = @(Get-WallpaperShortcutSpecs -Desktop 'C:\Desktop' -Programs 'C:\Programs' -Startup 'C:\Startup' -IncludeManual)
Assert-True ($specs.Count -eq 2) 'Manual icons are created only when explicitly requested'
Assert-True ($specs[0].path -eq (Join-Path 'C:\Desktop' $shortcutName)) 'Desktop shortcut has the requested exact name'
$specs = @(Get-WallpaperShortcutSpecs -Desktop 'C:\Desktop' -Programs 'C:\Programs' -Startup 'C:\Startup' -IncludeStartup)
Assert-True ($specs.Count -eq 1 -and $specs[0].path -eq 'C:\Startup\Codex Wallpaper Watcher.lnk' -and $specs[0].script -eq 'watcher-start.ps1' -and $specs[0].extra -eq '') 'Ordinary installation creates only its hidden Windows startup entry'
$owned = [pscustomobject]@{ path = $specs[0].path; target = 'C:\Windows\powershell.exe'; arguments = '-File C:\Helper\start.ps1'; description = 'Codex dynamic wallpaper helper' }
$actual = [pscustomobject]@{ TargetPath = $owned.target; Arguments = $owned.arguments; Description = $owned.description }
Assert-True (Test-OwnedWallpaperShortcut $owned $actual) 'Uninstaller recognizes exact recorded shortcuts'
$actual.Arguments = '-File C:\Other\start.ps1'
Assert-True (-not (Test-OwnedWallpaperShortcut $owned $actual)) 'Uninstaller keeps a shortcut replaced by the user'
$actual.Arguments = $owned.arguments
$owned.path = 'C:\Desktop\Codex.lnk'
Assert-True (-not (Test-OwnedWallpaperShortcut $owned $actual)) 'Uninstaller never removes the original Codex shortcut'
$owned.path = 'C:\Startup\Codex Wallpaper Watcher.lnk'
Assert-True (Test-OwnedWallpaperShortcut $owned $actual) 'Uninstaller recognizes the recorded English Startup shortcut'

Assert-True ([bool](Get-Command Save-WallpaperShortcut -ErrorAction SilentlyContinue)) 'Shortcut installer must provide a staging save helper'
$script:staging = @{ Final = 'C:\Programs\Codex Wallpaper Watcher.lnk'; State = 'C:\State\CodexChatWallpaper'; FinalExists = $false; Created = @(); Saved = @(); Copied = @(); Removed = @(); StageExists = $false; FailCopy = $false; ExistingDescription = 'Codex dynamic wallpaper helper' }
$shortcutShell = [pscustomobject]@{}
$shortcutShell | Add-Member ScriptMethod CreateShortcut {
  param($Path)
  $script:staging.Created += $Path
  $result = [pscustomobject]@{ Path = $Path; TargetPath = ''; Arguments = ''; WorkingDirectory = ''; IconLocation = ''; Description = $script:staging.ExistingDescription; WindowStyle = 0 }
  $result | Add-Member ScriptMethod Save { $script:staging.Saved += $this.Path; $script:staging.StageExists = $true }
  $result
}
function Test-Path {
  param($LiteralPath, $PathType)
  if ($LiteralPath -eq $script:staging.Final) { return $script:staging.FinalExists }
  return $script:staging.StageExists
}
function Copy-Item {
  param($LiteralPath, $Destination, [switch]$Force)
  if ($script:staging.FailCopy) { throw 'Mock copy failure' }
  $script:staging.Copied += [pscustomobject]@{ Source = $LiteralPath; Destination = $Destination; Force = [bool]$Force }
}
function Remove-Item { param($LiteralPath, [switch]$Force) $script:staging.Removed += $LiteralPath; $script:staging.StageExists = $false }
$saveArgs = @{ Shell = $shortcutShell; Destination = $script:staging.Final; ScriptPath = 'C:\Helper\watcher-start.ps1'; ExtraArguments = ''; IconPath = 'C:\Official\ChatGPT.exe'; PowerShellPath = 'C:\Windows\powershell.exe'; ToolDirectory = 'C:\Helper'; StateDirectory = $script:staging.State }
$savedLink = Save-WallpaperShortcut @saveArgs
Assert-True ($script:staging.Saved.Count -eq 1 -and (Split-Path $script:staging.Saved[0] -Parent) -eq $script:staging.State) 'COM saves shortcut only under the allowed state directory'
Assert-True ($script:staging.Saved[0] -like '*.lnk' -and $script:staging.Saved[0] -ne $script:staging.Final) 'COM staging path is a distinct link file'
Assert-True ($script:staging.Copied.Count -eq 1 -and $script:staging.Copied[0].Source -eq $script:staging.Saved[0] -and $script:staging.Copied[0].Destination -eq $script:staging.Final -and $script:staging.Copied[0].Force) 'Staged shortcut is copied to the exact granted destination'
Assert-True ($script:staging.Removed.Count -eq 1 -and $script:staging.Removed[0] -eq $script:staging.Saved[0]) 'Only this operation staging file is removed'
Assert-True ($savedLink.path -eq $script:staging.Final -and $savedLink.arguments -like '*-WindowStyle Hidden*watcher-start.ps1*') 'Manifest records the final path and hidden watcher command'
$script:staging.FailCopy = $true
$failed = $false
try { Save-WallpaperShortcut @saveArgs | Out-Null } catch { $failed = $_.Exception.Message -eq 'Mock copy failure' }
Assert-True ($failed -and $script:staging.Removed.Count -eq 2 -and -not $script:staging.StageExists) 'Copy failure still removes the unique staging shortcut'
Assert-True ($script:staging.Saved[0] -ne $script:staging.Saved[1]) 'Each shortcut save uses a unique staging path'
$script:staging.FinalExists = $true
$script:staging.ExistingDescription = 'Another program'
$failed = $false
try { Save-WallpaperShortcut @saveArgs | Out-Null } catch { $failed = $_.Exception.Message -like '*belongs to another program*' }
Assert-True ($failed -and $script:staging.Saved.Count -eq 2) 'Ownership mismatch prevents staging and overwrite'

$latestExe = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1024.9000.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
$runningExe = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1016.8622.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
$script:packages = @(
  [pscustomobject]@{ Version = [version]'26.1016.8622.0'; InstallLocation = (Split-Path (Split-Path $runningExe -Parent) -Parent) }
  [pscustomobject]@{ Version = [version]'26.1024.9000.0'; InstallLocation = (Split-Path (Split-Path $latestExe -Parent) -Parent) }
)
$script:validExePaths = @($latestExe, $runningExe)
$script:runningProcesses = @([pscustomobject]@{ Path = $runningExe })
function Get-AppxPackage { param($Name, $ErrorAction) $script:packages }
function Test-Path { param($LiteralPath, $PathType) $script:validExePaths -contains $LiteralPath }
function Get-OfficialCodexProcessRecords { foreach ($item in $script:runningProcesses) { [pscustomobject]@{ Executable = $item.Path } } }
Assert-True ((Get-CodexExe) -eq $latestExe) 'Executable resolver chooses the latest installed official package'
$script:packages = @()
Assert-True ((Get-CodexExe) -eq $runningExe) 'Executable resolver uses a running exact official package path if package lookup is empty'
$script:runningProcesses = @([pscustomobject]@{ Path = 'C:\Other\ChatGPT.exe' })
Assert-True ((Get-CodexExe) -eq $runningExe) 'Executable resolver rejects another app named ChatGPT and uses the known official fallback'


# Run background startup behavior with all OS mutations replaced by mocks.
$script:hasWatcher=$false; $script:hasMonitor=$false; $script:startedRoles=@(); $script:created=0; $script:released=0
$script:fakeMutex=[pscustomobject]@{}
$script:fakeMutex | Add-Member ScriptMethod WaitOne { param($Timeout) $true }
$script:fakeMutex | Add-Member ScriptMethod ReleaseMutex { $script:released++ }
$script:fakeMutex | Add-Member ScriptMethod Dispose {}
function New-Object { param($TypeName,$ArgumentList) if ($TypeName -eq 'System.Threading.Mutex') { return $script:fakeMutex }; throw 'Unexpected New-Object' }
function Get-WallpaperHelperRecord { param($RecordPath,$ExpectedScript,$Role) if (($Role -eq 'watcher' -and $script:hasWatcher) -or ($Role -eq 'monitor' -and $script:hasMonitor)) { return [pscustomobject]@{ pid=1234 } }; return $null }
function New-Item { param($ItemType,$Path,[switch]$Force) $script:created++ }
function Test-Path { param($LiteralPath,$PathType) return $LiteralPath -notlike '*monitor-stop.request' }
function Get-WallpaperNodePath { 'Invoke-TestNode' }
function Invoke-TestNode { param($VersionSwitch) $global:LASTEXITCODE=0; 'v22.0.0' }
function Start-WallpaperHelper { param($Executable,$Arguments,$Controller,$Role,$RecordPath,$LogName) $script:startedRoles += $Role }
Invoke-WallpaperBackgroundStart
Assert-True ($script:startedRoles.Count -eq 2 -and $script:startedRoles[0] -eq 'watcher' -and $script:startedRoles[1] -eq 'monitor') 'Missing background helpers start exactly one watcher and one ordinary-start monitor'
Assert-True ($script:released -eq 1) 'Background-start mutex is always released'
$script:hasWatcher=$true; $script:hasMonitor=$true; $script:startedRoles=@()
Invoke-WallpaperBackgroundStart
Assert-True (-not $script:startedRoles.Count) 'Both existing exact helpers are reused without duplicates'
$beforeCreates=$script:created
$ready=Invoke-WallpaperBackgroundStart -CheckOnly
Assert-True ($ready -eq $true -and -not $script:startedRoles.Count -and $script:created -eq $beforeCreates) 'CheckOnly requires both helpers and never creates or starts anything'
$script:hasMonitor=$false
$ready=Invoke-WallpaperBackgroundStart -CheckOnly
Assert-True ($ready -eq $false -and -not $script:startedRoles.Count -and $script:created -eq $beforeCreates) 'A watcher without a monitor does not falsely report complete startup integration'
Invoke-WallpaperBackgroundStart
Assert-True ($script:startedRoles.Count -eq 1 -and $script:startedRoles[0] -eq 'monitor') 'A missing monitor is repaired without replacing the active watcher'
Write-Output ('PASS: ' + $script:passed + ' shortcut and background startup checks')

