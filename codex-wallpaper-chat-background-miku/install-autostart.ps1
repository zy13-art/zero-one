param([switch]$StartWithWindows = $true, [switch]$CreateManualShortcuts)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexChatWallpaper'
$manifestPath = Join-Path $stateRoot 'shortcuts.json'
$shortcutName = 'Codex 动态壁纸.lnk'
$description = 'Codex dynamic wallpaper helper'
. (Join-Path $toolRoot 'windows-process.ps1')

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

function Get-WallpaperShortcutSpecs {
  param([string]$Desktop, [string]$Programs, [string]$Startup, [switch]$IncludeStartup, [switch]$IncludeManual)
  @(
    if ($IncludeManual) {
      [pscustomobject]@{ path = (Join-Path $Desktop $shortcutName); script = 'start.ps1'; extra = ' -Shortcut' }
      [pscustomobject]@{ path = (Join-Path $Programs $shortcutName); script = 'start.ps1'; extra = ' -Shortcut' }
    }
    if ($IncludeStartup) {
      [pscustomobject]@{ path = (Join-Path $Startup 'Codex Wallpaper Watcher.lnk'); script = 'watcher-start.ps1'; extra = '' }
    }
  )
}

function Save-WallpaperShortcut {
  param($Shell, [string]$Destination, [string]$ScriptPath, [string]$ExtraArguments,
    [string]$IconPath, [string]$PowerShellPath, [string]$ToolDirectory, [string]$StateDirectory)
  $ownerDescription = 'Codex dynamic wallpaper helper'
  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    $existing = $Shell.CreateShortcut($Destination)
    if ($existing.Description -ne $ownerDescription) {
      throw "A shortcut with this name already exists and belongs to another program: $Destination"
    }
  }
  $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"{1}' -f $ScriptPath, $ExtraArguments
  $stagingPath = Join-Path $StateDirectory ('shortcut-' + [guid]::NewGuid().ToString('N') + '.lnk')
  try {
    $link = $Shell.CreateShortcut($stagingPath)
    $link.TargetPath = $PowerShellPath
    $link.Arguments = $arguments
    $link.WorkingDirectory = $ToolDirectory
    $link.IconLocation = $IconPath + ',0'
    $link.Description = $ownerDescription
    $link.WindowStyle = 7
    $link.Save()
    Copy-Item -LiteralPath $stagingPath -Destination $Destination -Force
  } finally {
    if (Test-Path -LiteralPath $stagingPath -PathType Leaf) { Remove-Item -LiteralPath $stagingPath -Force }
  }
  return [pscustomobject]@{ path = $Destination; target = $PowerShellPath; arguments = $arguments; description = $ownerDescription }
}

$exe = Get-CodexExe
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$specs = @(Get-WallpaperShortcutSpecs -Desktop ([Environment]::GetFolderPath('DesktopDirectory')) `
  -Programs ([Environment]::GetFolderPath('Programs')) -Startup ([Environment]::GetFolderPath('Startup')) -IncludeStartup:$StartWithWindows -IncludeManual:$CreateManualShortcuts)
$shell = New-Object -ComObject WScript.Shell
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$links = @()
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  $previous = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $links = @($previous.links)
}
if (-not $CreateManualShortcuts) {
  $manualPaths = @((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) $shortcutName), (Join-Path ([Environment]::GetFolderPath('Programs')) $shortcutName))
  $retained = @()
  foreach ($old in $links) {
    if ($old.path -notin $manualPaths) { $retained += $old; continue }
    if (-not (Test-Path -LiteralPath $old.path -PathType Leaf)) { continue }
    $actual = $shell.CreateShortcut($old.path)
    if ($old.description -eq $description -and $actual.Description -eq $description -and $actual.TargetPath -ieq $old.target -and $actual.Arguments -ceq $old.arguments) {
      Remove-Item -LiteralPath $old.path -Force
      Write-Host ('Removed redundant wallpaper shortcut: ' + $old.path)
    } else { $retained += $old; Write-Warning ('Kept a shortcut changed by its owner: ' + $old.path) }
  }
  $links = $retained
}
foreach ($spec in $specs) {
  $scriptPath = Join-Path $toolRoot $spec.script
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Required helper script is missing: $scriptPath" }
  $record = Save-WallpaperShortcut -Shell $shell -Destination $spec.path -ScriptPath $scriptPath `
    -ExtraArguments $spec.extra -IconPath $exe -PowerShellPath $powerShell -ToolDirectory $toolRoot -StateDirectory $stateRoot
  $links = @($links | Where-Object { $_.path -ine $spec.path }) + @($record)
  @{ version = 1; links = $links } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  Write-Host ('Created shortcut: ' + $spec.path)
}
Write-Host 'The ordinary Codex desktop, taskbar, and Start Menu entries can trigger the wallpaper startup connection.'
if ($StartWithWindows) { Write-Host 'Windows sign-in starts the background helpers only. Existing Codex sessions are preserved; fully quit once to arm the next ordinary launch.' }
