# Shared read-only process checks. This file has no startup or shutdown side effects.
function Initialize-WallpaperWindowsApi {
  if ('CodexWallpaperWindowsProcess' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CodexWallpaperWindowsProcess {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(int id, out int session);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, IntPtr data, int length, out int returned);
  [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CommandLineToArgvW(string line, out int count);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr data);
  [StructLayout(LayoutKind.Sequential)] struct UnicodeString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
  public sealed class Identity { public int Id; public int SessionId; public string Executable; public DateTime Started; public long StartedTicks; public string CommandLine; public string[] Arguments; }
  public static string[] ParseArguments(string line) {
    int count; IntPtr argv=CommandLineToArgvW(line,out count);
    if(argv==IntPtr.Zero) return null;
    try { var result=new string[count]; for(int i=0;i<count;i++) result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv,i*IntPtr.Size)); return result; }
    finally { LocalFree(argv); }
  }
  public static Identity Read(int id) {
    IntPtr process=OpenProcess(0x1000,false,id);
    if(process==IntPtr.Zero) return null;
    try {
      int length=32768; var path=new StringBuilder(length); long created,exited,kernel,user;
      if(!QueryFullProcessImageName(process,0,path,ref length)||!GetProcessTimes(process,out created,out exited,out kernel,out user)) return null;
      var result=new Identity { Id=id, Executable=path.ToString(), Started=DateTime.FromFileTimeUtc(created) };
      int session; if(!ProcessIdToSessionId(id,out session)) return null; result.SessionId=session;
      result.StartedTicks=result.Started.Ticks;
      int needed; NtQueryInformationProcess(process,60,IntPtr.Zero,0,out needed);
      if(needed>0 && needed<1048576) {
        IntPtr buffer=Marshal.AllocHGlobal(needed);
        try { if(NtQueryInformationProcess(process,60,buffer,needed,out needed)>=0) { var text=(UnicodeString)Marshal.PtrToStructure(buffer,typeof(UnicodeString)); if(text.Buffer!=IntPtr.Zero && text.Length>0) result.CommandLine=Marshal.PtrToStringUni(text.Buffer,text.Length/2); } }
        finally { Marshal.FreeHGlobal(buffer); }
      }
      if(result.CommandLine!=null) result.Arguments=ParseArguments(result.CommandLine);
      return result;
    } finally { CloseHandle(process); }
  }
}
'@
}

function Get-WallpaperProcessIdentity {
  param([int]$ProcessId)
  Initialize-WallpaperWindowsApi
  [CodexWallpaperWindowsProcess]::Read($ProcessId)
}

function ConvertTo-WallpaperStartedTicks {
  param($Started)
  if ($Started -is [datetime]) { return $Started.ToUniversalTime().Ticks }
  [datetime]::Parse([string]$Started, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().Ticks
}

function Test-OfficialCodexPath {
  param([string]$Executable)
  $root = [regex]::Escape((Join-Path $env:ProgramFiles 'WindowsApps'))
  return $Executable -match ('^' + $root + '\\OpenAI\.Codex_\d+\.\d+\.\d+\.\d+_(?:x64|arm64|x86)__2p2nqsd0c76g0\\app\\ChatGPT\.exe$')
}

function Get-OfficialCodexProcessRecords {
  $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
  foreach ($process in @([Diagnostics.Process]::GetProcessesByName('ChatGPT'))) {
    try {
      $record = Get-WallpaperProcessIdentity -ProcessId $process.Id
      if ($record -and $record.SessionId -eq $sessionId -and (Test-OfficialCodexPath $record.Executable)) { $record }
    } catch {} finally { $process.Dispose() }
  }
}

function Test-WallpaperRecordedProcess {
  param($Record, [string]$ExpectedScript, [ValidateSet('watcher','monitor')][string]$Role)
  try {
    if (-not $Record -or [int]$Record.pid -le 0 -or -not $Record.started -or $Record.controller -ine $ExpectedScript) { return $false }
    $actual = Get-WallpaperProcessIdentity -ProcessId ([int]$Record.pid)
    $executable = if ($Record.executable) { [string]$Record.executable } else { [string]$Record.node }
    if (-not $actual -or -not $executable -or $actual.Executable -ine $executable -or $actual.StartedTicks -ne (ConvertTo-WallpaperStartedTicks $Record.started)) { return $false }
    $name = [IO.Path]::GetFileNameWithoutExtension($actual.Executable)
    if (($Role -eq 'watcher' -and $name -ine 'node') -or ($Role -eq 'monitor' -and $name -notin @('powershell','pwsh'))) { return $false }
    if (-not $actual.Arguments -or -not @($actual.Arguments | Where-Object { $_ -ieq $ExpectedScript }).Count) { return $false }
    if ($Role -eq 'watcher' -and $actual.Arguments -notcontains '--watch') { return $false }
    if ($Role -eq 'monitor' -and $actual.Arguments -notcontains '-File') { return $false }
    return $true
  } catch { return $false }
}

function Get-WallpaperTcpListeners {
  param([int]$Port = 9335)
  foreach ($line in @(& (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p TCP)) {
    if ($line -match ('^\s*TCP\s+(\S+):' + $Port + '\s+\S+\s+LISTENING\s+(\d+)\s*$')) {
      [pscustomobject]@{ Address = $Matches[1]; ProcessId = [int]$Matches[2] }
    }
  }
}

function Assert-WallpaperCdpOwner {
  param([int]$Port = 9335, [string]$ExpectedExecutable)
  $listeners = @(Get-WallpaperTcpListeners -Port $Port)
  if (-not $listeners.Count -or @($listeners | Where-Object { $_.Address -notin @('127.0.0.1','[::1]') }).Count) { throw 'Codex CDP must listen only on loopback.' }
  $owners = @($listeners | Select-Object -ExpandProperty ProcessId -Unique)
  if ($owners.Count -ne 1) { throw 'Codex CDP has an unexpected number of owners.' }
  $owner = Get-WallpaperProcessIdentity -ProcessId $owners[0]
  if (-not $owner -or -not (Test-OfficialCodexPath $owner.Executable)) { throw 'CDP owner is not the official Codex executable.' }
  if ($ExpectedExecutable -and $owner.Executable -ine $ExpectedExecutable) { throw 'CDP owner differs from the expected Codex executable.' }
}

function ConvertTo-WallpaperArgumentString {
  param([string[]]$Arguments)
  (@(foreach ($argument in $Arguments) {
    if ($argument -and $argument -notmatch '[\s"]') { $argument; continue }
    $escaped = [regex]::Replace([string]$argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    '"' + $escaped + '"'
  }) -join ' ')
}

function Get-WallpaperRelayArguments {
  param([string[]]$OriginalArguments, [string]$Profile, [int]$Port = 9335)
  if (-not $OriginalArguments -or $OriginalArguments.Count -lt 1) { throw 'Original Codex launch arguments are unavailable; refusing to discard activation parameters.' }
  $forward = @()
  for ($index = 1; $index -lt $OriginalArguments.Count; $index++) {
    $argument = $OriginalArguments[$index]
    if ($argument -match '^--(?:user-data-dir|remote-debugging-port|remote-debugging-address)(?:=|$)') {
      if ($argument -notlike '*=*' -and $index + 1 -lt $OriginalArguments.Count -and $OriginalArguments[$index + 1] -notlike '--*') { $index++ }
      continue
    }
    $forward += $argument
  }
  @($forward) + @(('--remote-debugging-port=' + $Port), '--remote-debugging-address=127.0.0.1', ('--user-data-dir=' + $Profile))
}
