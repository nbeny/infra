# Lance WoW.exe (original, intact sur le disque) puis neutralise EN MEMOIRE les
# trois controles d'integrite de l'interface qui affichent
# « Your game interface files are corrupt » (message 10 de Startup_Strings.dbc).
#
# Pourquoi en memoire : Smart App Control (Windows 11) bloque un WoW.exe
# modifie sur le disque, car il n'est ni signe ni connu de Microsoft. L'original
# est accepte ; ce script ne fait que le corriger une fois charge.
#
# WoW.exe n'a pas d'ASLR (ImageBase 0x400000 fixe) : les adresses sont stables.
#   0x48ff55  77 34 -> EB 3E   signature FrameXML (ja -> jmp vers le chargement)
#   0x49003c  74 0A -> EB 0A   empreinte MD5 de l'interface (je -> jmp)
#   0x51f567  74 0A -> EB 0A   meme comparaison, autre chemin de chargement
$ErrorActionPreference = 'Stop'
$log = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Logs\Lancer-Turtle.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
function L($m) { Add-Content -Path $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) }
L "---- lancement"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'WoW.exe'

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class TW {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct SI { public int cb; public string r, d, t; public int x,y,xs,ys,xc,yc,fa,fl; public short sw, r2; public IntPtr r3, i, o, e; }
  [StructLayout(LayoutKind.Sequential)]
  public struct PI { public IntPtr hP, hT; public int pid, tid; }
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inh, uint fl, IntPtr env, string cwd, ref SI si, out PI pi);
  [DllImport("kernel32", SetLastError=true)] public static extern bool VirtualProtectEx(IntPtr h, IntPtr a, IntPtr n, uint np, out uint op);
  [DllImport("kernel32", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out IntPtr w);
  [DllImport("kernel32", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out IntPtr r);
  [DllImport("kernel32")] public static extern bool FlushInstructionCache(IntPtr h, IntPtr a, IntPtr n);
  [DllImport("kernel32")] public static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32")] public static extern bool TerminateProcess(IntPtr h, uint c);
  [DllImport("kernel32")] public static extern bool CloseHandle(IntPtr h);
}
"@

$patches = @(
  @{ va = 0x48ff55; old = [byte[]](0x77,0x34); new = [byte[]](0xEB,0x3E) },
  @{ va = 0x49003c; old = [byte[]](0x74,0x0A); new = [byte[]](0xEB,0x0A) },
  @{ va = 0x51f567; old = [byte[]](0x74,0x0A); new = [byte[]](0xEB,0x0A) }
)

$si = New-Object TW+SI; $si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$pi = New-Object TW+PI
# 0x4 = CREATE_SUSPENDED : rien ne s'execute avant que les correctifs soient poses.
if (-not [TW]::CreateProcess($exe, "`"$exe`"", [IntPtr]::Zero, [IntPtr]::Zero, $false, 0x4, [IntPtr]::Zero, $dir, [ref]$si, [ref]$pi)) {
  throw "Lancement impossible : erreur Windows $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}
try {
  foreach ($p in $patches) {
    $a = [IntPtr]$p.va; $buf = New-Object byte[] 2; $n = [IntPtr]::Zero
    [void][TW]::ReadProcessMemory($pi.hP, $a, $buf, 2, [ref]$n)
    if (-not ([BitConverter]::ToString($buf) -eq [BitConverter]::ToString($p.old))) {
      throw ("Octets inattendus a 0x{0:x} ({1}) : ce n'est pas le WoW.exe prevu, rien n'a ete modifie." -f $p.va, [BitConverter]::ToString($buf))
    }
    $op = [uint32]0
    [void][TW]::VirtualProtectEx($pi.hP, $a, [IntPtr]2, 0x40, [ref]$op)
    if (-not [TW]::WriteProcessMemory($pi.hP, $a, $p.new, 2, [ref]$n)) { throw "Ecriture refusee a 0x$('{0:x}' -f $p.va)" }
    [void][TW]::VirtualProtectEx($pi.hP, $a, [IntPtr]2, $op, [ref]$op)
    $chk = New-Object byte[] 2; [void][TW]::ReadProcessMemory($pi.hP, $a, $chk, 2, [ref]$n)
    L ("0x{0:x}  {1} -> {2}" -f $p.va, [BitConverter]::ToString($buf), [BitConverter]::ToString($chk))
  }
  [void][TW]::FlushInstructionCache($pi.hP, [IntPtr]::Zero, [IntPtr]::Zero)
  [void][TW]::ResumeThread($pi.hT)
  L "WoW PID $($pi.pid) demarre avec les 3 correctifs"
  $wowPid = $pi.pid
} catch {
  L "ECHEC : $($_.Exception.Message)"
  [void][TW]::TerminateProcess($pi.hP, 1)
  Add-Type -AssemblyName System.Windows.Forms
  [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Lancer-Turtle')
} finally {
  [void][TW]::CloseHandle($pi.hT); [void][TW]::CloseHandle($pi.hP)
}



# Surveille 10 min : si WoW se relance lui-meme (nouveau WoW.exe dont le parent
# est WoW), cette copie n'est PAS corrigee -> on le note.
if ($wowPid) {
  $fin = (Get-Date).AddMinutes(10)
  while ((Get-Date) -lt $fin) {
    Get-CimInstance Win32_Process -Filter "Name='WoW.exe'" | Where-Object { $_.ProcessId -ne $wowPid } | ForEach-Object {
      L "ATTENTION : autre WoW.exe PID $($_.ProcessId) (parent $($_.ParentProcessId)) -- non corrige"
      $wowPid = $_.ProcessId
    }
    if (-not (Get-Process -Id $wowPid -ErrorAction SilentlyContinue)) { L "WoW PID $wowPid termine"; break }
    Start-Sleep -Seconds 2
  }
}

