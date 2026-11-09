# screen-time-counter - 屏幕点亮时长计数器
# 版本 1.3.0
#
# 记录屏幕真正亮着的时长。规则一句话：
#   屏幕亮着就算，屏幕灭了就停。不做任何「人在不在」的判断，也不看键盘鼠标有没有动。
# 一段 = 屏幕亮起（或程序启动）到屏幕灭掉（或程序退出、机器睡眠），整段计入，不做任何扣减。
# 紧邻的两段（间隔 60 秒内）会自动合并，免得重启一次就多出一段。
#
# 屏幕开关由系统的「显示器电源状态」通知驱动（GUID_CONSOLE_DISPLAY_STATE），是事件而不是猜。
# 没运行的那段时间可以用系统日志回填（-Backfill），降级口径是「机器在运行就算」。

param(
  [switch]$Once,        # 控制台模式：算一次并打印，然后退出
  [switch]$Detail,      # 控制台模式：打印明细文本后退出
  [switch]$Panel,       # 只把面板窗口打开（不启动托盘），方便看效果
  [switch]$Backfill,    # 用系统日志回填最近几天工具还没运行的时间
  [int]$BackfillDays = 7,
  [int]$IntervalSec = 30
)

$ToolVersion = '1.3.1'   # 版本号：第二行注释和 README 开头要跟它一致
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $Root 'state.json'
$BakPath   = Join-Path $Root 'state.bak.json'
$JournalPath = Join-Path $Root 'state.journal'
$LogPath   = Join-Path $Root 'screen-time.log'
$CatPath   = Join-Path $Root 'categories.json'

function Write-Log([string]$m) {
  try { Add-Content -Path $LogPath -Value ("{0}  {1}" -f (Get-Date).ToString('o'), $m) -Encoding UTF8 } catch {}
}

# ---------------------------------------------------------------- 系统接口

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# 查鼠标左键此刻是不是按着：用来判断「点到面板外面了」
Add-Type -Namespace ScreenTimeUi -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
'@ -ErrorAction SilentlyContinue

$csSource = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class ScreenTimeWatch : NativeWindow
{
    public static readonly Guid GUID_CONSOLE_DISPLAY_STATE =
        new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct POWERBROADCAST_SETTING
    {
        public Guid PowerSetting;
        public uint DataLength;
        public byte Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid PowerSettingGuid, uint Flags);

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    public static extern uint GetTickCount();

    public static uint IdleSeconds()
    {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(li);
        if (!GetLastInputInfo(ref li)) return 0;
        return (GetTickCount() - li.dwTime) / 1000;
    }

    public static Action<int> OnDisplayChanged;

    // 当前最前面的窗口属于哪个程序。用来把时间归到具体应用上。
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    public static string ForegroundApp()
    {
        try
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return "(无窗口)";
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == 0) return "(无窗口)";
            System.Diagnostics.Process p = System.Diagnostics.Process.GetProcessById((int)pid);
            string n = p.ProcessName;
            p.Dispose();
            if (string.IsNullOrEmpty(n)) return "(未知)";
            return n;
        }
        catch { return "(未知)"; }
    }

    // 最前面那个窗口的窗口类名。
    // explorer.exe 既管桌面/任务栏、也管文件夹窗口，靠类名把这两件事分开：
    //   CabinetWClass / ExploreWClass   = 真的在开文件夹
    //   Progman / WorkerW / Shell_TrayWnd = 桌面、任务栏，不算「在用某个程序」
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder buf, int nMaxCount);

    public static string ForegroundClass()
    {
        try
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return "";
            System.Text.StringBuilder sb = new System.Text.StringBuilder(256);
            int n = GetClassName(h, sb, sb.Capacity);
            if (n <= 0) return "";
            return sb.ToString();
        }
        catch { return ""; }
    }

    // 最前面那个窗口属于哪个进程，用来排除本工具自己
    public static int ForegroundPid()
    {
        try
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return 0;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return (int)pid;
        }
        catch { return 0; }
    }

    private Guid _guid = GUID_CONSOLE_DISPLAY_STATE;
    public bool Registered = false;

    public ScreenTimeWatch()
    {
        CreateHandle(new CreateParams());
        IntPtr r = RegisterPowerSettingNotification(this.Handle, ref _guid, 0);
        Registered = (r != IntPtr.Zero);
    }

    // 收到过的最后一次电源广播，给 PowerShell 那边轮询用（不依赖委托，避免回调绑不上）
    public static string LastBroadcast = "";

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0218)
        {
            // 实测这台机器上送来的 wParam 是 0x8013 而不是 SDK 文档里的 0x8014，
            // 所以两种都收，具体靠 GUID 和数据值判断。
            int wp = m.WParam.ToInt32();
            if (wp == 0x8013 || wp == 0x8014)
            {
                try
                {
                    POWERBROADCAST_SETTING s =
                        (POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(POWERBROADCAST_SETTING));
                    LastBroadcast = "wParam=0x" + wp.ToString("X") + " guid=" + s.PowerSetting.ToString() + " data=" + s.Data;
                    if (s.PowerSetting == GUID_CONSOLE_DISPLAY_STATE)
                    {
                        Action<int> cb = OnDisplayChanged;
                        if (cb != null) cb(s.Data);
                    }
                }
                catch { LastBroadcast = "wParam=0x" + wp.ToString("X") + " 解析失败"; }
            }
            else
            {
                LastBroadcast = "wParam=0x" + wp.ToString("X") + "（不是电源设置变化）";
            }
        }
        base.WndProc(ref m);
    }
}
'@
Add-Type -TypeDefinition $csSource -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Runtime.InteropServices | Out-Null

# ---------------------------------------------------------------- 状态

# 系统里有没有进程/驱动占着显示器（比如正在放视频）。
# 有的话，空闲再久屏幕也不会灭，兜底判断就不能只按空闲算。
function Test-DisplayRequested {
  try {
    $out = @(powercfg /requests 2>$null)
    $start = -1
    for ($i = 0; $i -lt $out.Count; $i++) { if ($out[$i] -match '^DISPLAY:') { $start = $i; break } }
    if ($start -lt 0) { return $false }
    for ($j = $start + 1; $j -lt [Math]::Min($start + 8, $out.Count); $j++) {
      if ($out[$j] -match '^\S') { break }
      if ($out[$j] -match '\[PROCESS\]|\[DRIVER\]') { return $true }
    }
    return $false
  } catch { return $false }
}

# 读系统的灭屏时间（秒）。收不到电源通知时用它兜底判断。
function Get-MonitorTimeoutSec {
  try {
    $out = powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null
    $line = ($out | Select-String -Pattern '当前交流电源设置索引|Current AC Power Setting Index' | Select-Object -First 1).Line
    if ($line -match '0x([0-9a-fA-F]+)') { return [Convert]::ToInt32($matches[1], 16) }
  } catch {}
  return 300
}

# 启动时先猜一下屏幕状态：读 WMI 里的显示器活动标志。
# 那个值不一定实时，只用来定起始状态，之后的判断以通知（或空闲兜底）为准。
function Get-DisplayOnGuess {
  try {
    $m = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop)
    if ($m.Count -eq 0) { return $true }
    return (@($m | Where-Object { $_.Active }).Count -gt 0)
  } catch { return $true }
}

function Get-DayKey($d) { return ([datetime]$d).ToString('yyyy-MM-dd') }   # 参数不声明类型，避免被转成区域格式

# 娱乐程序名单：列在里面的从「办公时长」里扣掉，但单独显示。
# 名单放在 categories.json 里，可以自己改；不在名单里的一律按办公算。
$script:FunAppsDefault = @('steam','steamwebhelper','steamservice','epicgameslauncher','wegame','Battle.net','RiotClientServices')
function Get-FunApps {
  try {
    if (Test-Path $CatPath) {
      $j = Get-Content $CatPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.PSObject.Properties['娱乐']) {
        $list = @($j.'娱乐' | Where-Object { $_ })
        if ($list.Count -gt 0) { return $list }
      }
    }
  } catch { Write-Log "categories.json 读不了，用默认名单：$($_.Exception.Message)" }
  return $script:FunAppsDefault
}
function Test-FunApp([string]$name) {
  if (-not $name) { return $false }
  foreach ($a in $script:FunApps) { if ($name -ieq $a) { return $true } }
  return $false
}

# 「不记」名单：默认空着。真正管用的是下面那条「是不是我拉起来的」判断。
# 名单留着是给你自己用——想把某个程序彻底排除，就往 categories.json 的「不记」里加。
$script:SkipAppsDefault = @()
function Get-SkipApps {
  try {
    if (Test-Path $CatPath) {
      $j = Get-Content $CatPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.PSObject.Properties['不记']) {
        return @($j.'不记' | Where-Object { $_ })
      }
    }
  } catch { Write-Log "categories.json 的「不记」读不了：$($_.Exception.Message)" }
  return $script:SkipAppsDefault
}
function Test-SkipApp([string]$name) {
  if (-not $name) { return $true }
  foreach ($a in $script:SkipApps) { if ($name -ieq $a) { return $true } }
  return $false
}

# 「宿主」：我自己（AI）就是被这个程序拉起来的。
# 判断某个前台窗口是谁开的，靠顺着父进程往上找：
#   先碰到宿主  -> 是我操作的，不记
#   先碰到 explorer -> 是你自己点开的，照记
# 这样「你手动开的 PowerShell」和「我跑命令拉起来的 PowerShell」就分开了。
$script:HostAppsDefault = @('DSH NEXT')
function Get-HostApps {
  try {
    if (Test-Path $CatPath) {
      $j = Get-Content $CatPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.PSObject.Properties['宿主']) {
        $list = @($j.'宿主' | Where-Object { $_ })
        if ($list.Count -gt 0) { return $list }
      }
    }
  } catch { Write-Log "categories.json 的「宿主」读不了，用默认：$($_.Exception.Message)" }
  return $script:HostAppsDefault
}

function Test-AgentSpawned([int]$targetPid) {
  if ($targetPid -le 0) { return $false }
  try {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop)
    $map = @{}
    foreach ($p in $all) { $map[[int]$p.ProcessId] = $p }
    $cur = $targetPid
    for ($i = 0; $i -lt 10; $i++) {
      if (-not $map.ContainsKey($cur)) { break }
      $parentId = [int]$map[$cur].ParentProcessId
      if ($parentId -le 0 -or -not $map.ContainsKey($parentId)) { break }
      $pname = [string]$map[$parentId].Name
      $base = $pname -replace '\.exe$', ''
      foreach ($h in $script:HostApps) { if ($base -ieq $h) { return $true } }
      if ($base -ieq 'explorer') { return $false }
      $cur = $parentId
    }
  } catch {}
  return $false
}

# 能不能证明「这个窗口是你自己点开的」：父进程链里能走到 explorer 就算。
# 我自己跑命令拉起来的进程活得短，父进程一退出链就断了，断链的一律当作不算。
function Test-UserLaunched([int]$targetPid) {
  if ($targetPid -le 0) { return $false }
  try {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop)
    $map = @{}
    foreach ($p in $all) { $map[[int]$p.ProcessId] = $p }
    $cur = $targetPid
    for ($i = 0; $i -lt 10; $i++) {
      if (-not $map.ContainsKey($cur)) { return $false }
      $parentId = [int]$map[$cur].ParentProcessId
      if ($parentId -le 0 -or -not $map.ContainsKey($parentId)) { return $false }
      $base = ([string]$map[$parentId].Name) -replace '\.exe$', ''
      if ($base -ieq 'explorer') { return $true }
      $cur = $parentId
    }
  } catch {}
  return $false
}

# 控制台那类窗口（powershell / cmd / 终端）：多半是脚本或自动化拉起来的。
# 只有能证明是你自己开的时候才记。
$script:ConsoleApps = @('powershell', 'pwsh', 'cmd', 'conhost', 'OpenConsole', 'WindowsTerminal', 'wscript', 'cscript')

# 这个前台窗口到底该不该记。集中在这里判断，别在几个调用点各写一套。
function Test-ShouldSkipApp([int]$fgPid, [string]$name) {
  if ($fgPid -le 0) { return $true }
  if ($fgPid -eq $PID) { return $true }                 # 本工具自己
  if (-not $name) { return $true }
  if (Test-SkipApp $name) { return $true }               # 用户明确排除的
  if (Test-AgentSpawned $fgPid) { return $true }         # 我（AI）拉起来的
  # explorer：点桌面、点任务栏不算，只有文件夹窗口才算
  if ($name -ieq 'explorer') {
    $cls = [ScreenTimeWatch]::ForegroundClass()
    if ($cls -ne 'CabinetWClass' -and $cls -ne 'ExploreWClass') { return $true }
    return $false
  }
  foreach ($a in $script:ConsoleApps) {
    if ($name -ieq $a) { return (-not (Test-UserLaunched $fgPid)) }
  }
  return $false
}

# 某一天按程序分的行（含正在进行的那个程序）
function Get-DayAppRows($state, $d) {
  $k = Get-DayKey $d
  $rows = @()
  if ($state.days.PSObject.Properties[$k]) {
    $day = $state.days.$k
    if ($day.PSObject.Properties['apps']) {
      foreach ($p in @($day.apps.PSObject.Properties)) {
        if (Test-SkipApp $p.Name) { continue }   # 控制台那类不显示
        $rows += [pscustomobject]@{ n = $p.Name; v = [int64]$p.Value; o = [int64]0 }
      }
    }
    if ($day.PSObject.Properties['appsOff']) {
      foreach ($p in @($day.appsOff.PSObject.Properties)) {
        if (Test-SkipApp $p.Name) { continue }
        $found = $false
        foreach ($r in $rows) { if ($r.n -eq $p.Name) { $r.o += [int64]$p.Value; $found = $true } }
        if (-not $found) { $rows += [pscustomobject]@{ n = $p.Name; v = [int64]0; o = [int64]$p.Value } }
      }
    }
  }
  if ($script:AppStart -and $script:AppName -and (Get-DayKey $script:AppStart) -eq $k) {
    $live = [int][Math]::Round((New-TimeSpan -Start $script:AppStart -End (Get-Date)).TotalSeconds)
    $found = $false
    foreach ($r in $rows) {
      if ($r.n -eq $script:AppName) {
        if ($state.offline) { $r.o += $live } else { $r.v += $live }
        $found = $true
      }
    }
    if (-not $found) {
      if ($state.offline) { $rows += [pscustomobject]@{ n = $script:AppName; v = [int64]0; o = [int64]$live } }
      else { $rows += [pscustomobject]@{ n = $script:AppName; v = [int64]$live; o = [int64]0 } }
    }
  }
  return $rows
}

function Get-DayFun($state, $d) {
  $sum = [int64]0
  foreach ($r in (Get-DayAppRows $state $d)) { if (Test-FunApp $r.n) { $sum += [int64]$r.v } }
  return $sum
}

# 办公时长 = 屏幕时长 − 娱乐程序的时长 − 离线区间（不小于 0）。
# 离线是手动开关：机器还在跑、还在记录，但那段时间不算你在上班。
function Get-DayWork($state, $d) {
  $w = [int64](Get-DaySeconds $state $d) - [int64](Get-DayFun $state $d) - [int64](Get-DayOffline $state $d)
  if ($w -lt 0) { $w = 0 }
  return $w
}

function New-State {
  [pscustomobject]@{
    keyVersion  = 1
    days        = [pscustomobject]@{}
    current     = $null      # 正在计时的那一段的开始时间
    lastTick    = $null
    offline     = $false     # 手动离线模式：时间照记，但不并进办公时长
    offlineFrom = $null      # 这一段离线从什么时候开始
  }
}

function Load-State {
  if (-not (Test-Path $StatePath)) { return $null }
  try {
    $s = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $s.PSObject.Properties['days'])    { $s | Add-Member -NotePropertyName days -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $s.PSObject.Properties['current']) { $s | Add-Member -NotePropertyName current -NotePropertyValue $null }
    if (-not $s.PSObject.Properties['lastTick']){ $s | Add-Member -NotePropertyName lastTick -NotePropertyValue $null }
    if (-not $s.PSObject.Properties['offline'])    { $s | Add-Member -NotePropertyName offline    -NotePropertyValue $false }
    if (-not $s.PSObject.Properties['offlineFrom']){ $s | Add-Member -NotePropertyName offlineFrom -NotePropertyValue $null }
    return $s
  } catch {
    # 读不出来（被写到一半、被截断）**不等于**第一次运行：留一份残骸再重新开始
    $bad = "$StatePath.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    try { Move-Item -Path $StatePath -Destination $bad -Force } catch {}
    Write-Log "state.json 读不了，先留成 $(Split-Path $bad -Leaf) 再重新开始：$($_.Exception.Message)"
    return $null
  }
}

function Write-Journal([string]$payload) {
  try {
    $line = ('{0}|{1}' -f (Get-Date).ToString('o'), $payload)
    [System.IO.File]::AppendAllText($JournalPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Get-JournalLast {
  if (-not (Test-Path $JournalPath)) { return $null }
  try {
    $tail = @(Get-Content $JournalPath -Tail 8 -Encoding UTF8)
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
      $p = $tail[$i] -split '\|', 4
      if ($p.Count -eq 4) { return [pscustomobject]@{ at = [datetime]::Parse($p[0]); current = $p[1]; app = $p[2]; appStart = $p[3] } }
    }
  } catch {}
  return $null
}

function Save-State($s) {
  try {
    $s.lastTick = (Get-Date).ToString('o')
    # 正在计的那个程序也存下来：不然进程一旦重启，这段应用时间就丢了
    if (-not $s.PSObject.Properties['appName'])  { $s | Add-Member -NotePropertyName appName  -NotePropertyValue $null }
    if (-not $s.PSObject.Properties['appStart']) { $s | Add-Member -NotePropertyName appStart -NotePropertyValue $null }
    $s.appName  = $script:AppName
    $s.appStart = if ($script:AppStart) { ([datetime]$script:AppStart).ToString('o') } else { $null }
    # 正在计的这一段也写进存档（起点 + 现在），面板和外部读取都能实时看到，不用等段关闭
    if (-not $s.PSObject.Properties['live']) { $s | Add-Member -NotePropertyName live -NotePropertyValue $null }
    $s.live = if ($s.current) { [pscustomobject]@{ s = $s.current; e = (Get-Date).ToString('o') } } else { $null }
    $tmp = "$StatePath.tmp"
    [System.IO.File]::WriteAllText($tmp, ($s | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    # 原子替换：File.Replace 在 NTFS 上是一次改名，目标要么是旧文件要么是新文件，
    # 不会出现「文件消失 / 内容被截成空字节」的窗口。Move-Item -Force 是删了再改名，有那个窗口。
    try {
      [System.IO.File]::Replace($tmp, $StatePath, $null)
    } catch {
      if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
      [System.IO.File]::Move($tmp, $StatePath)
    }
    # 每次心跳追加一条：state.json 坏了也能从这里把正在计的那段捞回来
    Write-Journal ((@($s.current, $s.appName, $s.appStart) | ForEach-Object { if ($null -eq $_) { '' } else { $_ } }) -join '|')
    # 备份一小时刷新一次，坏文件最多丢一小时
    if (-not $script:BakAt -or ((Get-Date) - $script:BakAt).TotalMinutes -ge 60) {
      try { Copy-Item -Path $StatePath -Destination $BakPath -Force; $script:BakAt = Get-Date } catch {}
    }
  } catch { Write-Log "保存状态失败：$($_.Exception.Message)" }
}

function Ensure-Day($state, $d) {
  $k = Get-DayKey $d
  if (-not $state.days.PSObject.Properties[$k]) {
    $state.days | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{ seconds = 0; segments = @(); apps = [pscustomobject]@{}; appsOff = [pscustomobject]@{}; off = @(); live = $null })
  } else {
    if (-not $state.days.$k.PSObject.Properties['apps'])    { $state.days.$k | Add-Member -NotePropertyName apps    -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $state.days.$k.PSObject.Properties['appsOff']) { $state.days.$k | Add-Member -NotePropertyName appsOff -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $state.days.$k.PSObject.Properties['off'])     { $state.days.$k | Add-Member -NotePropertyName off     -NotePropertyValue @() }
  }
  return $k
}

# 把一段时间记到某个程序头上。离线那段记到 appsOff，办公/娱乐的合计都看不到它，
# 但面板上按程序的柱子会把它用另一种颜色拼出来。
function Add-AppSeconds($state, [datetime]$at, [string]$name, [int]$sec, [switch]$Off) {
  if ($sec -lt 1 -or -not $name) { return }
  $k = Ensure-Day $state $at
  $apps = if ($Off) { $state.days.$k.appsOff } else { $state.days.$k.apps }
  $old = 0
  if ($apps.PSObject.Properties[$name]) { $old = [int64]$apps.$name }
  if ($apps.PSObject.Properties[$name]) { $apps.$name = $old + [int64]$sec }
  else { $apps | Add-Member -NotePropertyName $name -NotePropertyValue ([int64]$sec) }
}

# 应用切片：屏幕亮着的时候，每隔一会儿问一次「现在最前面是哪个程序」，
# 换了就结算上一段，这样时间才能归到具体应用上
function Start-AppSlice($state, [datetime]$at) {
  if (-not $state.current) { return }
  $fpid = [ScreenTimeWatch]::ForegroundPid()
  $fg = [ScreenTimeWatch]::ForegroundApp()
  # 该不该记，统一由 Test-ShouldSkipApp 判断：
  # 本工具自己的窗口、我（AI）拉起来的、点桌面/任务栏、证明不了是你开的控制台，都不记
  if (Test-ShouldSkipApp $fpid $fg) { return }
  $script:AppName  = $fg
  $script:AppStart = $at
}

function Close-AppSlice($state, [datetime]$at) {
  if (-not $script:AppStart) { return }
  $from = $script:AppStart
  $name = $script:AppName
  $script:AppStart = $null
  $script:AppName  = $null
  if ($at -lt $from) { $at = $from }
  # 程序时长也要按天切开，理由跟整段一样：跨零点的一段整块记给开始那天，
  # 「按程序分」就会昨天多、今天少，和上面的大字对不上。
  $bounds = @($from)
  $cur = $from.Date.AddDays(1)
  while ($cur -lt $at) { $bounds += $cur; $cur = $cur.AddDays(1) }
  $bounds += $at
  for ($i = 0; $i -lt $bounds.Count - 1; $i++) {
    $sec = [int][Math]::Round(($bounds[$i + 1] - $bounds[$i]).TotalSeconds)
    Add-AppSeconds $state $bounds[$i] $name $sec -Off:([bool]$state.offline)
  }
}

# 记一段离线区间，按天切开（跟整段同样的理由：跨零点要分到两天）。
function Add-OfflineInterval($state, [datetime]$from, [datetime]$to) {
  if ($to -le $from) { return }
  $bounds = @($from)
  $cur = $from.Date.AddDays(1)
  while ($cur -lt $to) { $bounds += $cur; $cur = $cur.AddDays(1) }
  $bounds += $to
  for ($i = 0; $i -lt $bounds.Count - 1; $i++) {
    $a = $bounds[$i]; $b = $bounds[$i + 1]
    $sec = [int][Math]::Round(($b - $a).TotalSeconds)
    if ($sec -lt 1) { continue }
    $k = Ensure-Day $state $a
    $day = $state.days.$k
    $list = @($day.off)
    $merged = $false
    if ($list.Count -gt 0) {
      $last = $list[-1]
      if (($a - [datetime]::Parse($last.e)).TotalSeconds -le 60) {
        $last.e = $b.ToString('o'); $last.sec = [int]$last.sec + $sec
        $day.off = $list; $merged = $true
      }
    }
    if (-not $merged) { $day.off = @($list + [pscustomobject]@{ s = $a.ToString('o'); e = $b.ToString('o'); sec = $sec }) }
  }
}

# 某一天的离线区间：存下来的 + 正在进行的，而且只算和「屏幕亮着」重叠的部分。
# 只取离线区间本身的话，睡眠那段也会被算成离线，跟屏幕总时长对不上。
function Get-DayOfflineRanges($state, $d) {
  $k = Get-DayKey $d
  $dayStart = $d.Date; $dayEnd = $dayStart.AddDays(1)
  $screen = @()
  if ($state.days.PSObject.Properties[$k]) {
    foreach ($sg in @($state.days.$k.segments)) {
      if ($null -eq $sg -or -not $sg.s -or -not $sg.e) { continue }
      $screen += ,@([datetime]::Parse($sg.s), [datetime]::Parse($sg.e))
    }
  }
  if ($state.current) { $screen += ,@([datetime]::Parse($state.current), (Get-Date)) }
  $offs = @()
  if ($state.days.PSObject.Properties[$k]) {
    foreach ($o in @($state.days.$k.off)) {
      if ($null -eq $o -or -not $o.s -or -not $o.e) { continue }
      $offs += ,@([datetime]::Parse($o.s), [datetime]::Parse($o.e))
    }
  }
  if ($state.offline -and $state.offlineFrom) { $offs += ,@([datetime]::Parse($state.offlineFrom), (Get-Date)) }
  $out = @()
  foreach ($o in $offs) {
    $s = [datetime]$o[0]; if ($s -lt $dayStart) { $s = $dayStart }
    $e = [datetime]$o[1]; if ($e -gt $dayEnd) { $e = $dayEnd }
    if ($e -le $s) { continue }
    foreach ($sg in $screen) {
      $s2 = [datetime]$sg[0]; if ($s2 -lt $s) { $s2 = $s }
      $e2 = [datetime]$sg[1]; if ($e2 -gt $e) { $e2 = $e }
      if ($e2 -gt $s2) { $out += [pscustomobject]@{ s = $s2; e = $e2; sec = [int][Math]::Round(($e2 - $s2).TotalSeconds) } }
    }
  }
  return $out
}

function Get-DayOffline($state, $d) {
  $sum = [int64]0
  foreach ($r in @(Get-DayOfflineRanges $state $d)) { $sum += [int64]$r.sec }
  return $sum
}

function Get-RangeOffline($state, [datetime]$endDay, [int]$days) {
  $sum = [int64]0
  for ($i = 0; $i -lt $days; $i++) { $sum += [int64](Get-DayOffline $state $endDay.AddDays(-$i)) }
  return $sum
}

# 开关离线模式：先把当前应用切片收尾（不留跨模式的一段），再切模式；
# 关掉时把这段离线记进当天的 off 里，屏幕还亮着就重新起一应用切片。
function Set-OfflineMode($state, [bool]$on, [datetime]$at) {
  if ([bool]$state.offline -eq $on) { return }
  Close-AppSlice $state $at
  if ($on) {
    $state.offline = $true
    $state.offlineFrom = $at.ToString('o')
    Write-Log "离线模式：开（从 $($at.ToString('HH:mm:ss')) 起不计入办公时长）"
  } else {
    if ($state.offlineFrom) { Add-OfflineInterval $state ([datetime]::Parse($state.offlineFrom)) $at }
    $state.offline = $false
    $state.offlineFrom = $null
    Write-Log "离线模式：关（$($at.ToString('HH:mm:ss'))）"
  }
  if ($state.current -and $script:DisplayOn) { Start-AppSlice $state $at }
}

# 把一段已经确定结束的时间记到它所属的那一天（同一天里紧邻的两段合并）。
# 调用方保证 [from, to] 不跨天。
function Add-ClosedSegment($state, [datetime]$from, [datetime]$to, [int]$counted) {
  $k = Ensure-Day $state $from
  $day = $state.days.$k
  $day.seconds = [int64]$day.seconds + [int64]$counted
  $seg = [pscustomobject]@{
    s   = $from.ToString('o')
    e   = $to.ToString('o')
    sec = $counted
  }
  # 紧邻的上一段（间隔 60 秒内）合并，免得重启一次就多出一段
  $segs = @($day.segments)
  $merged = $false
  if ($segs.Count -gt 0) {
    $last = $segs[-1]
    if (($from - [datetime]::Parse($last.e)).TotalSeconds -le 60) {
      $last.e   = $to.ToString('o')
      $last.sec = [int]$last.sec + $counted
      $day.segments = $segs
      $merged = $true
    }
  }
  if (-not $merged) { $day.segments = @($segs + $seg) }
  return $merged
}

# 收尾一段：屏幕灭了（或者程序退出、检测到挂起）就把 [开始, 结束] 整段记下来
# 规则只有一条：屏幕亮着就算，灭了就停。不做任何「人走没走」的判断。
function Close-Segment($state, [datetime]$endAt) {
  if (-not $state.current) { return }
  Close-AppSlice $state $endAt
  $start = [datetime]::Parse($state.current)
  if ($endAt -lt $start) { $endAt = $start }

  # 跨零点的一段要按天切开。以前整段记给「开始的那一天」，
  # 于是从昨晚一直用到今天早上的话，今天一开面板几乎看不到东西
  # （零点之后的时长全被算进了昨天），看着像没记录。
  # 回填那条路本来就是把区间夹在当天边界里的，这里跟它对齐。
  $bounds = @($start)
  $cur = $start.Date.AddDays(1)
  while ($cur -lt $endAt) { $bounds += $cur; $cur = $cur.AddDays(1) }
  $bounds += $endAt

  for ($i = 0; $i -lt $bounds.Count - 1; $i++) {
    $a = $bounds[$i]
    $b = $bounds[$i + 1]
    $sec = ($b - $a).TotalSeconds
    if ($sec -lt 0) { $sec = 0 }
    $counted = [int][Math]::Round($sec)
    if ($counted -lt 1) { continue }
    $merged = Add-ClosedSegment $state $a $b $counted
    Write-Log "记一段 $($a.ToString('HH:mm:ss')) -> $($b.ToString('HH:mm:ss'))，$counted 秒$(if($merged){'，已并入上一段'})"
  }
  $state.current = $null
}

function Start-Segment($state, [datetime]$at) {
  if ($state.current) { return }
  $state.current = $at.ToString('o')
  Start-AppSlice $state $at
}

# 从系统日志推「机器醒着」的时间段，用来回填工具还没运行时的那部分。
# 注意：日志里只有开关机和睡眠唤醒，没有屏幕开关，所以这是估算。
function Get-AwakeIntervals([datetime]$from, [datetime]$to) {
  $marks = @()
  try {
    # 12/6005 = 开机；42 = 进入睡眠；13/1074/6006 = 关机相关
    $ev = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$from.AddDays(-2); EndTime=$to; Id=@(12,13,42,1074,6005,6006)} -ErrorAction Stop
    foreach ($e in $ev) {
      $k = if ($e.Id -eq 12 -or $e.Id -eq 6005) { 'boot' } else { 'off' }
      $marks += [pscustomobject]@{ t = $e.TimeCreated; k = $k }
    }
  } catch {}
  try {
    $pt = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter'; StartTime=$from.AddDays(-2); EndTime=$to} -ErrorAction Stop
    foreach ($e in $pt) { $marks += [pscustomobject]@{ t = $e.TimeCreated; k = 'wake' } }
  } catch {}
  $marks = @($marks | Sort-Object t)
  $out = @(); $cur = $null; $prev = $null
  foreach ($m in $marks) {
    if ($m.k -eq 'wake') {
      if (-not $cur) { $cur = $m.t }
    } elseif ($m.k -eq 'off') {
      if ($cur) { $out += [pscustomobject]@{ s = $cur; e = $m.t }; $cur = $null }
    } else {
      # 开机：说明之前是关着的。手上那段只能收在上一个痕迹的时刻，
      # 不能收到开机时刻，否则中间的关机时间会被算成醒着。
      if ($cur) {
        $closeAt = if ($prev -and $prev -gt $cur) { $prev } else { $cur }
        if ($closeAt -gt $cur) { $out += [pscustomobject]@{ s = $cur; e = $closeAt } }
        $cur = $null
      }
      $cur = $m.t
    }
    $prev = $m.t
  }
  if ($cur) { $out += [pscustomobject]@{ s = $cur; e = $to } }
  return $out
}

# 把一天的段按时间排好，合并间隔 60 秒以内的相邻段，最后重算当天总秒数
function Optimize-DaySegments($state, $k) {
  if (-not $state.days.PSObject.Properties[$k]) { return }
  $day = $state.days.$k
  $segs = @($day.segments | Sort-Object { [datetime]::Parse($_.s) })
  $out = @()
  foreach ($sg in $segs) {
    if ($out.Count -gt 0) {
      $last = $out[-1]
      if (([datetime]::Parse($sg.s) - [datetime]::Parse($last.e)).TotalSeconds -le 60) {
        $last.e = $sg.e
        $last.sec = [int]$last.sec + [int]$sg.sec
        if ($sg.PSObject.Properties['est']) {
          if ($last.PSObject.Properties['est']) { $last.est = $true }
          else { $last | Add-Member -NotePropertyName est -NotePropertyValue $true }
        }
        continue
      }
    }
    $out += $sg
  }
  $day.segments = @($out)
  $sum = [int64]0
  foreach ($sg in $out) { $sum += [int64]$sg.sec }
  $day.seconds = $sum
}

# 回填：把工具还没运行的那些天按「机器醒着」补进记录，标成估算。
# 只补到「已经记过的最早一刻」为止，避免和实测数据重叠。
function Invoke-Backfill($state, [datetime]$now, [int]$days) {
  $total = 0
  for ($i = $days - 1; $i -ge 0; $i--) {
    $dayStart = $now.Date.AddDays(-$i)
    $dayEnd   = $dayStart.AddDays(1)
    if ($dayEnd -gt $now) { $dayEnd = $now }
    $k = Get-DayKey $dayStart

    # 这一天已经记过的最早一刻（只有今天会有）
    $earliest = $null
    if ($state.days.PSObject.Properties[$k]) {
      foreach ($sg in @($state.days.$k.segments)) {
        $t = [datetime]::Parse($sg.s)
        if (-not $earliest -or $t -lt $earliest) { $earliest = $t }
      }
    }
    if ($state.current -and (Get-DayKey ([datetime]::Parse($state.current))) -eq $k) {
      $t = [datetime]::Parse($state.current)
      if (-not $earliest -or $t -lt $earliest) { $earliest = $t }
    }
    $to = if ($earliest) { $earliest } else { $dayEnd }
    if ($to -le $dayStart) { continue }

    foreach ($iv in (Get-AwakeIntervals $dayStart $dayEnd)) {
      $s = $iv.s; $e = $iv.e
      if ($s -lt $dayStart) { $s = $dayStart }
      if ($e -gt $to)      { $e = $to }
      if ($e -le $s) { continue }
      $sec = [int][Math]::Round(($e - $s).TotalSeconds)
      if ($sec -lt 60) { continue }

      Ensure-Day $state $dayStart | Out-Null
      $day = $state.days.$k
      $seg = [pscustomobject]@{ s = $s.ToString('o'); e = $e.ToString('o'); sec = $sec; est = $true }
      $day.segments = @(@($day.segments) + $seg)
      $day.seconds = [int64]$day.seconds + [int64]$sec
      $total += $sec
      Write-Log "回填 $k $($s.ToString('HH:mm:ss')) -> $($e.ToString('HH:mm:ss'))，$sec 秒"
    }
    # 统一排序、合并、重算总秒数，避免插入历史区间时把相邻判断搞乱
    Optimize-DaySegments $state $k
  }
  return $total
}

# 最近 N 天的合计（含正在计时的那段）
function Get-RangeSeconds($state, [datetime]$endDay, [int]$days) {
  $sum = [int64]0
  for ($i = 0; $i -lt $days; $i++) {
    $d = $endDay.AddDays(-$i)
    $k = Get-DayKey $d
    if ($state.days.PSObject.Properties[$k]) { $sum += [int64]$state.days.$k.seconds }
  }
  if ($state.current) {
    $start = [datetime]::Parse($state.current)
    if ($start -ge $endDay.Date.AddDays(-($days - 1))) {
      $live = [int](New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds
      if ($live -gt 0) { $sum += [int64]$live }
    }
  }
  return $sum
}

# 最近 N 天里，娱乐程序的合计
function Get-RangeFun($state, [datetime]$endDay, [int]$days) {
  $sum = [int64]0
  for ($i = 0; $i -lt $days; $i++) { $sum += [int64](Get-DayFun $state $endDay.AddDays(-$i)) }
  return $sum
}

# 最近 N 天里，按程序汇总。v = 在线（办公/娱乐），o = 离线区间里的运行时长。
function Get-RangeApps($state, [datetime]$endDay, [int]$days) {
  $acc = @{}
  for ($i = 0; $i -lt $days; $i++) {
    $k = Get-DayKey $endDay.AddDays(-$i)
    if (-not $state.days.PSObject.Properties[$k]) { continue }
    $day = $state.days.$k
    if ($day.PSObject.Properties['apps']) {
      foreach ($p in @($day.apps.PSObject.Properties)) {
        if (-not $acc.ContainsKey($p.Name)) { $acc[$p.Name] = [pscustomobject]@{ v = [int64]0; o = [int64]0 } }
        $acc[$p.Name].v += [int64]$p.Value
      }
    }
    if ($day.PSObject.Properties['appsOff']) {
      foreach ($p in @($day.appsOff.PSObject.Properties)) {
        if (-not $acc.ContainsKey($p.Name)) { $acc[$p.Name] = [pscustomobject]@{ v = [int64]0; o = [int64]0 } }
        $acc[$p.Name].o += [int64]$p.Value
      }
    }
  }
  return $acc
}

# ---------------------------------------------------------------- 显示

function Format-HM([int]$sec) {
  if ($sec -le 0) { return '0 秒' }
  if ($sec -lt 60) { return "$sec 秒" }
  # 必须向下取整：以前写的是 [int]($sec / 3600)，那是四舍五入，
  # 5 小时 50 分会显示成「6 小时 50 分」——分钟一到 30 就多算一小时。
  $h = [int][math]::Floor($sec / 3600); $m = [int][math]::Floor(($sec % 3600) / 60)
  if ($h -gt 0 -and $m -gt 0) { return "$h 小时 $m 分" }
  if ($h -gt 0) { return "$h 小时" }
  return "$m 分"
}

function Get-DaySeconds($state, $d) {
  $k = Get-DayKey $d
  $base = [int64]0
  if ($state.days.PSObject.Properties[$k]) { $base = [int64]$state.days.$k.seconds }
  $live = 0
  # 正在计时的那一段也算进去（末尾的空闲要等收尾时才扣）。
  # 但要夹在当天的边界里：它可能昨天就开始了，也可能现在还开着——
  # 前者不能算到今天头上，后者不能把今天之后的（不存在的）时间算进来。
  if ($state.current) {
    $from = [datetime]::Parse($state.current)
    $to   = Get-Date
    if ($from -lt $d.Date) { $from = $d.Date }
    if ($to -gt $d.Date.AddDays(1)) { $to = $d.Date.AddDays(1) }
    if ($to -gt $from) {
      $live = [int](New-TimeSpan -Start $from -End $to).TotalSeconds
      if ($live -lt 0) { $live = 0 }
    }
  }
  return $base + [int64]$live
}

function Get-DaySegmentCount($state, $d) {
  $k = Get-DayKey $d
  $n = 0
  if ($state.days.PSObject.Properties[$k]) { $n = @($state.days.$k.segments).Count }
  # 这段只要和当天有重叠就算一段——跨零点的那段会同时算进两天
  if ($state.current) {
    $cs = [datetime]::Parse($state.current)
    if ($cs -lt $d.Date.AddDays(1) -and (Get-Date) -ge $d.Date) { $n++ }
  }
  return $n
}

function New-TimeIcon([int]$sec) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 200, 110, 0))), 0, 0, 31, 31)
  # 同样要向下取整，不然图标上的小时数也会多算一小时
  $h = [int][math]::Floor($sec / 3600); $m = [int][math]::Floor(($sec % 3600) / 60)
  $txt = "${h}:$($m.ToString('00'))"
  $size = switch ($txt.Length) { 1 {16} 2 {15} 3 {13} 4 {11} 5 {9} default {8} }
  $font = New-Object System.Drawing.Font 'Segoe UI', $size, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $fmt  = New-Object System.Drawing.StringFormat
  $fmt.Alignment = [System.Drawing.StringAlignment]::Center
  $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
  $g.DrawString($txt, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $fmt)
  $g.Dispose()
  $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
  $bmp.Dispose()
  return $ico
}

function Get-TooltipText($state, [datetime]$now) {
  $work = Get-DayWork $state $now
  $fun  = Get-DayFun $state $now
  $off  = Get-DayOffline $state $now
  $yw   = Get-DayWork $state $now.AddDays(-1)
  $line = "今天：办公 $(Format-HM $work)"
  if ($fun -gt 0) { $line += "`n娱乐 $(Format-HM $fun)" }
  if ($off -gt 0) { $line += "  离线 $(Format-HM $off)" }
  if ($state.offline) { $line = "[离线中]`n" + $line }
  $full = "屏幕时间`n$line`n昨天：办公 $(Format-HM $yw)"
  if ($full.Length -le 63) { return $full }
  $mid = "屏幕时间`n今天：办公 $(Format-HM $work)`n昨天：办公 $(Format-HM $yw)"
  if ($mid.Length -le 63) { return $mid }
  return "办公 $(Format-HM $work)"
}

# 按比例画一条横条，最长的那个画满
function Format-Bar([int64]$v, [int64]$max, [int]$width = 18) {
  if ($max -le 0 -or $v -le 0) { return '' }
  $n = [int][Math]::Round($v * $width / $max)
  if ($n -lt 1) { $n = 1 }
  return ('█' * $n)
}

function Get-DetailText($state, [datetime]$now) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("生成时间：$($now.ToString('yyyy-MM-dd HH:mm:ss'))")

  foreach ($pair in @(@('今天', $now), @('昨天', $now.AddDays(-1)))) {
    $label = $pair[0]; $d = $pair[1]
    $k = Get-DayKey $d
    $sec = Get-DaySeconds $state $d
    $funSec = Get-DayFun $state $d
    $offSec = Get-DayOffline $state $d
    $workSec = [int64]$sec - [int64]$funSec - [int64]$offSec
    if ($workSec -lt 0) { $workSec = 0 }
    $cnt = Get-DaySegmentCount $state $d
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("【$label】$k")
    $max3 = [Math]::Max([Math]::Max($workSec, $funSec), $offSec)
    [void]$sb.AppendLine(("    办公 " + (Format-HM $workSec).PadLeft(13) + "  " + (Format-Bar $workSec $max3)))
    [void]$sb.AppendLine(("    娱乐 " + (Format-HM $funSec).PadLeft(13) + "  " + (Format-Bar $funSec $max3)))
    [void]$sb.AppendLine(("    离线 " + (Format-HM $offSec).PadLeft(13) + "  " + (Format-Bar $offSec $max3)))
    [void]$sb.AppendLine(("    合计 " + (Format-HM $sec).PadLeft(13)))
    $segs = @()
    if ($state.days.PSObject.Properties[$k]) { $segs = @($state.days.$k.segments) }
    if ($segs.Count -eq 0 -and $cnt -eq 0) { [void]$sb.AppendLine('    （没有记录）') }
    $maxSeg = 0
    foreach ($sg in $segs) { if ([int]$sg.sec -gt $maxSeg) { $maxSeg = [int]$sg.sec } }
    foreach ($sg in $segs) {
      $s0 = [datetime]::Parse($sg.s).ToString('HH:mm')
      $e0 = [datetime]::Parse($sg.e).ToString('HH:mm')
      [void]$sb.AppendLine("    $s0 – $e0" + (Format-HM $sg.sec).PadLeft(13) + "  " + (Format-Bar ([int64]$sg.sec) ([int64]$maxSeg)))
    }
    if ($state.current) {
      $s0 = [datetime]::Parse($state.current)
      $vs = $s0
      if ((Get-DayKey $vs) -ne $k) {
        $vs = $d.Date
        if ($vs -lt $s0) { $vs = $s0 }
      }
      if ((Get-DayKey $vs) -eq $k) {
        [void]$sb.AppendLine("    $($vs.ToString('HH:mm')) – 现在" + "（还在算）".PadLeft(11))
      }
    }
    # 按程序分（娱乐的标出来）
    $rows = Get-DayAppRows $state $d
    if ($rows.Count -gt 0) {
      $sorted = @($rows | Sort-Object -Property @{Expression='v';Descending=$true})
      $maxApp = 0
      foreach ($r in $sorted) { $totMax = [int64]$r.v + [int64]$r.o; if ($totMax -gt $maxApp) { $maxApp = $totMax } }
      [void]$sb.AppendLine('    按程序分：')
      foreach ($r in $sorted) {
        $tagApp = if (Test-FunApp $r.n) { ' 娱乐' } else { '' }
        $totR = [int64]$r.v + [int64]$r.o
        $offTag = if ([int64]$r.o -gt 0) { '  离线 ' + (Format-HM $r.o) } else { '' }
        [void]$sb.AppendLine("      " + $r.n.PadRight(18) + (Format-HM $totR).PadLeft(12) + "  " + (Format-Bar $totR $maxApp) + $tagApp + $offTag)
      }
    }
  }
  # 最后才是近 7 天：今天和昨天放前面
  $r7 = Get-RangeSeconds $state $now 7
  $f7 = Get-RangeFun $state $now 7
  $o7 = Get-RangeOffline $state $now 7
  $w7 = [int64]$r7 - [int64]$f7 - [int64]$o7
  if ($w7 -lt 0) { $w7 = 0 }
  $from7 = $now.Date.AddDays(-6).ToString('MM-dd')
  $to7   = $now.Date.ToString('MM-dd')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("【近 7 天】$from7 ~ $to7")
  $max7 = [Math]::Max([Math]::Max($w7, $f7), $o7)
  [void]$sb.AppendLine(("    办公 " + (Format-HM $w7).PadLeft(13) + "  " + (Format-Bar $w7 $max7)))
  [void]$sb.AppendLine(("    娱乐 " + (Format-HM $f7).PadLeft(13) + "  " + (Format-Bar $f7 $max7)))
  [void]$sb.AppendLine(("    离线 " + (Format-HM $o7).PadLeft(13) + "  " + (Format-Bar $o7 $max7)))
  [void]$sb.AppendLine(("    合计 " + (Format-HM $r7).PadLeft(13)))
  $apps7 = Get-RangeApps $state $now 7
  $top = @()
  foreach ($n in $apps7.Keys) { $top += [pscustomobject]@{ n = $n; v = [int64]$apps7[$n].v; o = [int64]$apps7[$n].o } }
  if ($script:AppStart -and $script:AppName) {
    $live = [int][Math]::Round((New-TimeSpan -Start $script:AppStart -End (Get-Date)).TotalSeconds)
    $found = $false
    foreach ($t in $top) {
      if ($t.n -eq $script:AppName) {
        if ($state.offline) { $t.o += $live } else { $t.v += $live }
        $found = $true
      }
    }
    if (-not $found) {
      if ($state.offline) { $top += [pscustomobject]@{ n = $script:AppName; v = [int64]0; o = [int64]$live } }
      else { $top += [pscustomobject]@{ n = $script:AppName; v = [int64]$live; o = [int64]0 } }
    }
  }
  if ($top.Count -gt 0) {
    $top5 = @($top | Sort-Object -Property @{Expression={ [int64]$_.v + [int64]$_.o };Descending=$true} | Select-Object -First 5)
    $maxTop = 0
    foreach ($t in $top5) { $totTop = [int64]$t.v + [int64]$t.o; if ($totTop -gt $maxTop) { $maxTop = $totTop } }
    [void]$sb.AppendLine('    用得最多的前 5 个：')
    $rank = 0
    foreach ($t in $top5) {
      $rank++
      $tagT = if (Test-FunApp $t.n) { ' 娱乐' } else { '' }
      $totT = [int64]$t.v + [int64]$t.o
      $offT = if ([int64]$t.o -gt 0) { '  离线 ' + (Format-HM $t.o) } else { '' }
      [void]$sb.AppendLine("      $rank. " + $t.n.PadRight(16) + (Format-HM $totT).PadLeft(12) + "  " + (Format-Bar $totT $maxTop) + $tagT + $offT)
    }
  }

  return $sb.ToString()
}

# ---------------------------------------------------------------- 界面

function Initialize-WinForms {
  if ($script:WinFormsReady) { return }
  try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
  [System.Windows.Forms.Application]::EnableVisualStyles()
  # 界面里的异常不要弹那个吓人的框，写进日志，连带堆栈
  try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
      param($s, $e)
      Write-Log "界面异常：$($e.Exception.ToString())"
    })
  } catch { Write-Log "装界面异常记录失败：$($_.Exception.Message)" }
  $script:WinFormsReady = $true
}

# ---------------------------------------------------------------- 面板（自绘）
# 三个工具共用同一套外观：同一个尺寸、同一套配色、同一种画法。

$script:UiBg    = [System.Drawing.Color]::FromArgb(255, 249, 250, 251)
$script:UiCard  = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
$script:UiText  = [System.Drawing.Color]::FromArgb(255, 28, 32, 38)
$script:UiMuted = [System.Drawing.Color]::FromArgb(255, 138, 147, 158)
$script:UiWork  = [System.Drawing.Color]::FromArgb(255, 45, 108, 223)
$script:UiFun   = [System.Drawing.Color]::FromArgb(255, 240, 148, 65)
$script:UiOff   = [System.Drawing.Color]::FromArgb(255, 122, 138, 158)   # 离线段：灰蓝
$script:UiTrack = [System.Drawing.Color]::FromArgb(255, 232, 236, 241)
$script:UiHover = [System.Drawing.Color]::FromArgb(255, 240, 148, 65)
$script:UiLine  = [System.Drawing.Color]::FromArgb(255, 222, 227, 233)

function Get-UiFonts {
  if (-not $script:FTitle) {
    $script:FTitle = New-Object System.Drawing.Font 'Microsoft YaHei UI', 21, ([System.Drawing.FontStyle]::Bold)
    $script:FTab   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5
    $script:FTabB  = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5, ([System.Drawing.FontStyle]::Bold)
    $script:FSub   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $script:FApp   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $script:FTiny  = New-Object System.Drawing.Font 'Microsoft YaHei UI', 7.5
    # 关闭按钮单独一个大字号，原来那个 × 太小
    $script:FClose = New-Object System.Drawing.Font 'Microsoft YaHei UI', 14, ([System.Drawing.FontStyle]::Regular)
  }
}

# 圆角矩形
function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  if ($r -le 0 -or $w -le 0 -or $h -le 0) { $p.AddRectangle((New-Object System.Drawing.RectangleF $x, $y, $w, $h)); return $p }
  if ($r -gt $h / 2) { $r = $h / 2 }
  if ($r -gt $w / 2) { $r = $w / 2 }
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# 面板上要显示的程序排行（今天/昨天/近 7 天通用）
function Get-PanelApps($st, [datetime]$now, [int]$rng) {
  if ($rng -eq 2) {
    $map = Get-RangeApps $st $now 7
    $rows = @()
    foreach ($n in $map.Keys) { $rows += [pscustomobject]@{ n = $n; v = [int64]$map[$n].v; o = [int64]$map[$n].o } }
  } else {
    $rows = @(Get-DayAppRows $st $now.AddDays(-$rng))
  }
  if ($script:AppStart -and $script:AppName -and $rng -ne 1) {
    $live = [int][Math]::Round((New-TimeSpan -Start $script:AppStart -End (Get-Date)).TotalSeconds)
    $found = $false
    foreach ($r in $rows) {
      if ($r.n -eq $script:AppName) {
        if ($script:State -and $script:State.offline) { $r.o += $live } else { $r.v += $live }
        $found = $true
      }
    }
    if (-not $found) {
      if ($script:State -and $script:State.offline) { $rows += [pscustomobject]@{ n = $script:AppName; v = [int64]0; o = [int64]$live } }
      else { $rows += [pscustomobject]@{ n = $script:AppName; v = [int64]$live; o = [int64]0 } }
    }
  }
  # 2026-10-15：原来只取前 6 行。今天有 6 个程序时 OpenCode 正好排第 6，
  # 但它的秒数少、看着像"没被记录"。放宽到 8 行，菜单长的日子也能看全。
  return @($rows | Sort-Object -Property @{Expression={ [int64]$_.v + [int64]$_.o };Descending=$true} | Select-Object -First 8)
}

# 自绘面板必须开双缓冲，不然定时重画时整块会闪一下。
# DoubleBuffered 是受保护的属性，直接赋值得反射；用 Control.SetStyle 更稳。
function Set-PanelDoubleBuffer($form) {
  try {
    $styles = [int]([System.Windows.Forms.ControlStyles]::UserPaint)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::Opaque)
    $m = [System.Windows.Forms.Control].GetMethod('SetStyle', [System.Reflection.BindingFlags]'NonPublic,Instance')
    [void]$m.Invoke($form, @([System.Windows.Forms.ControlStyles]$styles, $true))
  } catch { Write-Log "double buffer unavailable: $($_.Exception.Message)" }
}

# 面板高度按「这一栏实际有几个程序」算：从「今天」切到「近 7 天」，程序条数会变，
# 高度不跟着变的话，最后一行程序就和底下那排柱子挤在一起了。
function Get-ScreenPanelHeight($st, [datetime]$now, [int]$rng) {
  $n = @(Get-PanelApps $st $now $rng).Count
  if ($n -lt 1) { $n = 1 }
  return (176 + $n * 24 + 82)
}

function Draw-Panel($g, [int]$w, [int]$h) {
  Get-UiFonts
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear($script:UiBg)

  $now = Get-Date
  $st = $script:State
  $rng = [int]$script:PanelRange   # 0 今天 1 昨天 2 近 7 天

  if ($rng -eq 2) {
    $label = '近 7 天'
    $sec    = [int64](Get-RangeSeconds $st $now 7)
    $funSec = [int64](Get-RangeFun $st $now 7)
    $offSec = [int64](Get-RangeOffline $st $now 7)
  } else {
    $d = $now.AddDays(-$rng)
    $label = if ($rng -eq 0) { '今天' } else { '昨天' }
    $sec    = [int64](Get-DaySeconds $st $d)
    $funSec = [int64](Get-DayFun $st $d)
    $offSec = [int64](Get-DayOffline $st $d)
  }
  # 办公 = 屏幕 − 娱乐 − 离线；离线那段机器在跑，但不计入上班时长
  $workSec = $sec - $funSec - $offSec
  if ($workSec -lt 0) { $workSec = 0 }

  # ---- 顶部三个标签
  $tabs = @('今天', '昨天', '近 7 天')
  $tx = 16
  $script:TabRects = @()
  for ($i = 0; $i -lt 3; $i++) {
    $fnt = if ($i -eq $rng) { $script:FTabB } else { $script:FTab }
    $col = if ($i -eq $rng) { $script:UiWork } else { $script:UiMuted }
    $sz = $g.MeasureString($tabs[$i], $fnt)
    $br = New-Object System.Drawing.SolidBrush $col
    $g.DrawString($tabs[$i], $fnt, $br, $tx, 12)
    $br.Dispose()
    $script:TabRects += [pscustomobject]@{ x = $tx; w = [int]$sz.Width; i = $i }
    if ($i -eq $rng) {
      $pen = New-Object System.Drawing.Pen $script:UiWork, 2
      $g.DrawLine($pen, $tx, 32, $tx + $sz.Width - 2, 32)
      $pen.Dispose()
    }
    $tx += [int]$sz.Width + 18
  }

  # 右上角：离线开关（拨动式，跟面板同一套配色，不做文字按钮）+ 关闭按钮
  $swW = 42; $swH = 22; $swX = $w - 40 - 6 - $swW; $swY = 8
  $offOn = [bool]$st.offline
  $lblTxt = '离线'
  # 字号跟面板里「屏幕 / 娱乐 / 离线」那一行一致；用居中排版，别让字偏上
  $lblSz = $g.MeasureString($lblTxt, $script:FSub)
  $lblX = $swX - 9 - $lblSz.Width
  $bLbl = New-Object System.Drawing.SolidBrush $(if ($offOn) { $script:UiOff } else { $script:UiMuted })
  $lblFmt = New-Object System.Drawing.StringFormat
  $lblFmt.Alignment = [System.Drawing.StringAlignment]::Near
  $lblFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
  $lblRect = New-Object System.Drawing.RectangleF ([single]$lblX), ([single]$swY), ([single]($lblSz.Width + 2)), ([single]$swH)
  $g.DrawString($lblTxt, $script:FSub, $bLbl, $lblRect, $lblFmt)
  $lblFmt.Dispose()
  $bLbl.Dispose()
  # 轨道：关是浅灰描边，开是灰蓝
  $tkGp = New-RoundRect $swX $swY $swW $swH 11
  $tkBr = New-Object System.Drawing.SolidBrush $(if ($offOn) { $script:UiOff } else { $script:UiTrack })
  $g.FillPath($tkBr, $tkGp); $tkBr.Dispose()
  if (-not $offOn) { $penT = New-Object System.Drawing.Pen $script:UiLine, 1; $g.DrawPath($penT, $tkGp); $penT.Dispose() }
  # 圆钮：白底 + 极浅投影，位置表示开关状态
  $knD = $swH - 4
  $knX = if ($offOn) { $swX + $swW - $knD - 2 } else { $swX + 2 }
  $knY = $swY + 2
  $knSh = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(24, 0, 0, 0))
  $g.FillEllipse($knSh, [single]($knX + 0.5), [single]($knY + 1), [single]$knD, [single]$knD)
  $knSh.Dispose()
  $knBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
  $g.FillEllipse($knBr, [single]$knX, [single]$knY, [single]$knD, [single]$knD)
  $knBr.Dispose()
  $tkGp.Dispose()
  $script:PanelToggleRect = [pscustomobject]@{ x = ($lblX - 6); y = ($swY - 5); w = (($swX + $swW) - ($lblX - 6)); h = ($swH + 10) }
  $bClose = New-Object System.Drawing.SolidBrush $script:UiMuted
  $g.DrawString('×', $script:FClose, $bClose, ($w - 30), 2)
  $bClose.Dispose()
  $script:PanelCloseRect = [pscustomobject]@{ x = ($w - 40); y = 0; w = 36; h = 34 }

  # ---- 大字号时长
  $big = (Format-HM $workSec)
  $bBig = New-Object System.Drawing.SolidBrush $script:UiText
  $g.DrawString($big, $script:FTitle, $bBig, 14, 44)
  $szBig = $g.MeasureString($big, $script:FTitle)
  $bSub = New-Object System.Drawing.SolidBrush $script:UiMuted
  $g.DrawString("屏幕 $(Format-HM $sec)   ·   娱乐 $(Format-HM $funSec)   ·   离线 $(Format-HM $offSec)", $script:FSub, $bSub, 18, 40 + $szBig.Height)

  # ---- 办公 / 娱乐 占比条
  $barY = 118; $barX = 16; $barW = $w - 32; $barH = 12
  $gp = New-RoundRect $barX $barY $barW $barH 6
  $tb = New-Object System.Drawing.SolidBrush $script:UiTrack
  $g.FillPath($tb, $gp); $tb.Dispose(); $gp.Dispose()
  if ($sec -gt 0) {
    $xW = [single]($barW * $workSec / $sec)
    if ($xW -gt 0) {
      $gp = New-RoundRect $barX $barY $xW $barH 6
      $b = New-Object System.Drawing.SolidBrush $script:UiWork
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
    $xF = [single]($barW * $funSec / $sec)
    if ($xF -gt 0) {
      $gp = New-RoundRect ($barX + $xW) $barY $xF $barH 6
      $b = New-Object System.Drawing.SolidBrush $script:UiFun
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
    $xO = [single]($barW - $xW - $xF)
    if ($xO -gt 0) {
      $gp = New-RoundRect ($barX + $xW + $xF) $barY $xO $barH 6
      $b = New-Object System.Drawing.SolidBrush $script:UiOff
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
  }

  # ---- 按程序分
  $bTitle = New-Object System.Drawing.SolidBrush $script:UiText
  $g.DrawString('按程序分', $script:FTabB, $bTitle, 16, 142)
  $y = 164
  $top = Get-PanelApps $st $now $rng
  if ($top.Count -eq 0) {
    $g.DrawString('（还没有数据）', $script:FTiny, $bSub, 16, $y)
  } else {
    $maxA = 1
    foreach ($r in $top) { $tot = [int64]$r.v + [int64]$r.o; if ($tot -gt $maxA) { $maxA = $tot } }
    foreach ($r in $top) {
      $col = if (Test-FunApp $r.n) { $script:UiFun } else { $script:UiWork }
      $nm = $r.n
      if ($nm.Length -gt 14) { $nm = $nm.Substring(0, 13) + '…' }
      $g.DrawString($nm, $script:FApp, $bTitle, 16, $y)
      $bx = 132; $bw = 200; $bh = 9
      $gp = New-RoundRect $bx ($y + 3) $bw $bh 4
      $b = New-Object System.Drawing.SolidBrush $script:UiTrack
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      $totR = [int64]$r.v + [int64]$r.o
      $xw = [single]($bw * $r.v / $maxA)
      $xo = [single]($bw * $r.o / $maxA)
      if ($xw -gt 0) {
        $gp = New-RoundRect $bx ($y + 3) $xw $bh 4
        $b = New-Object System.Drawing.SolidBrush $col
        $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      }
      if ($xo -gt 0) {
        $gp = New-RoundRect ($bx + $xw) ($y + 3) $xo $bh 4
        $b = New-Object System.Drawing.SolidBrush $script:UiOff
        $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      }
      $bDur = New-Object System.Drawing.SolidBrush $script:UiText
      $g.DrawString((Format-HM $totR), $script:FApp, $bDur, ($w - 16 - 72), $y)
      $bDur.Dispose()
      $y += 24
    }
  }

  # ---- 底部：今天/昨天画 24 小时时间轴，近 7 天画每天一根竖条
  $baseY = $h - 40
  $bTitle.Dispose(); $bSub.Dispose(); $bBig.Dispose()
  if ($rng -eq 2) {
    $dayW = [int](($w - 32) / 7)
    $maxD = 1
    $vals = @()
    for ($i = 6; $i -ge 0; $i--) {
      $dd = $now.AddDays(-$i)
      $vv = [int64](Get-DaySeconds $st $dd)
      $vf = [int64](Get-DayFun $st $dd)
      $vo = [int64](Get-DayOffline $st $dd)
      $vw = $vv - $vf - $vo
      if ($vw -lt 0) { $vw = 0 }
      $vals += [pscustomobject]@{ d = $dd; v = $vv; f = $vf; o = $vo; w = $vw }
      if ($vv -gt $maxD) { $maxD = $vv }
    }
    # 鼠标停在哪根柱子上：那根高亮，并在它上方写出日期和时长
    $hx0 = [int]$script:PanelHoverX
    $hy0 = [int]$script:PanelHoverY
    $hotBar = -1
    if ($hy0 -ge ($h - 58)) {
      for ($j = 0; $j -lt $vals.Count; $j++) {
        $bx0 = 16 + $j * $dayW
        if ($hx0 -ge $bx0 -and $hx0 -lt ($bx0 + $dayW)) { $hotBar = $j; break }
      }
    }
    $i = 0
    foreach ($v in $vals) {
      $bx = 16 + $i * $dayW
      $hot = ($hotBar -eq $i)
      # 三段从下往上堆：办公(蓝) → 娱乐(橙) → 离线(灰蓝)，总高=屏幕时长
      $yTop = $baseY + 24
      $segCols = @(
        @{ n = [int64]$v.w; c = $(if ($i -eq 6 -or $hot) { $script:UiWork } else { [System.Drawing.Color]::FromArgb(255, 150, 175, 235) }) },
        @{ n = [int64]$v.f; c = $script:UiFun },
        @{ n = [int64]$v.o; c = $script:UiOff }
      )
      foreach ($sc in $segCols) {
        if ($sc.n -le 0) { continue }
        $sh = [int](28 * $sc.n / $maxD)
        if ($sh -lt 1) { $sh = 1 }
        $gp = New-RoundRect ($bx + 6) ($yTop - $sh) ($dayW - 14) $sh 2
        $b = New-Object System.Drawing.SolidBrush $(if ($hot) { $script:UiHover } else { $sc.c })
        $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
        $yTop -= $sh
      }
      $btxt = New-Object System.Drawing.SolidBrush $(if ($hot) { $script:UiText } else { $script:UiMuted })
      $g.DrawString($v.d.ToString('MM-dd'), $script:FTiny, $btxt, ($bx + 2), ($baseY + 26))
      $btxt.Dispose()
      $i++
    }
    if ($hotBar -ge 0) {
      $one = $vals[$hotBar]
      $htxt = $one.d.ToString('MM-dd') + '  办公 ' + (Format-HM $one.w) + ' · 离线 ' + (Format-HM $one.o)
      $hb = New-Object System.Drawing.SolidBrush $script:UiText
      $hw = $g.MeasureString($htxt, $script:FTiny).Width
      $hx = 16 + $hotBar * $dayW + ($dayW - $hw) / 2
      if ($hx -lt 16) { $hx = 16 }
      if ($hx + $hw -gt ($w - 8)) { $hx = $w - 8 - $hw }
      $g.DrawString($htxt, $script:FTiny, $hb, [single]$hx, [single]($baseY - 14))
      $hb.Dispose()
    }
  } else {
    $d = $now.AddDays(-$rng)
    $k = Get-DayKey $d
    $segs = @()
    if ($st.days.PSObject.Properties[$k] -and $st.days.$k.PSObject.Properties['segments']) { $segs = @($st.days.$k.segments | Where-Object { $_ -and $_.s -and $_.e }) }
    # 正在计的那一段也画出来（从存档里的 live 取，跨零点时裁到当天）
    if ($st.PSObject.Properties['live'] -and $st.live) {
      try {
        $ls = [datetime]::Parse($st.live.s); $le = [datetime]::Parse($st.live.e)
        $cs = if ($ls -lt $d.Date) { $d.Date } else { $ls }
        $ce = if ($le -gt $d.Date.AddDays(1)) { $d.Date.AddDays(1) } else { $le }
        if ($ce -gt $cs) { $segs = @($segs + [pscustomobject]@{ s = $cs.ToString('o'); e = $ce.ToString('o'); sec = [int]($ce - $cs).TotalSeconds; live = $true }) }
      } catch {}
    }
    $gp = New-RoundRect 16 $baseY ($w - 32) 16 4
    $b = New-Object System.Drawing.SolidBrush $script:UiTrack
    $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    $dayStart = $d.Date
    $span = 86400.0
    $offRanges = @(Get-DayOfflineRanges $st $d)
    # 鼠标停在时间轴上时：高亮压到的那一段，并显示精确的起止时间
    $hoverX = [int]$script:PanelHoverX
    $hovering = ($hoverX -ge 16 -and $hoverX -le ($w - 16))
    $hoverSeg = $null
    foreach ($sg in $segs) {
      if ($null -eq $sg -or -not $sg.s -or -not $sg.e) { continue }
      $s0 = [datetime]::Parse($sg.s); $e0 = [datetime]::Parse($sg.e)
      $x1 = 16 + ($s0 - $dayStart).TotalSeconds / $span * ($w - 32)
      $x2 = 16 + ($e0 - $dayStart).TotalSeconds / $span * ($w - 32)
      if ($x2 - $x1 -lt 1.5) { $x2 = $x1 + 1.5 }
      $isHover = ($hovering -and $hoverX -ge $x1 -and $hoverX -le $x2)
      if ($isHover) { $hoverSeg = $sg }
      $gp = New-RoundRect ([single]$x1) $baseY ([single]($x2 - $x1)) 16 3
      $b = New-Object System.Drawing.SolidBrush $(if ($isHover) { $script:UiHover } else { $script:UiWork })
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
    # 离线段压在时间轴上层：同样一段屏幕时间，离线的那截用灰蓝画出来
    $hoverOff = $null
    foreach ($og in $offRanges) {
      $ox1 = 16 + ($og.s - $dayStart).TotalSeconds / $span * ($w - 32)
      $ox2 = 16 + ($og.e - $dayStart).TotalSeconds / $span * ($w - 32)
      if ($ox2 - $ox1 -lt 1.5) { $ox2 = $ox1 + 1.5 }
      if ($hovering -and $hoverX -ge $ox1 -and $hoverX -le $ox2) { $hoverOff = $og }
      $gp = New-RoundRect ([single]$ox1) $baseY ([single]($ox2 - $ox1)) 16 3
      $b = New-Object System.Drawing.SolidBrush $script:UiOff
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
    if ($hovering) {
      $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 120, 132, 148)), 1
      $g.DrawLine($pen, [single]$hoverX, [single]($baseY - 4), [single]$hoverX, [single]($baseY + 16))
      $pen.Dispose()
      $secAt = [int](($hoverX - 16) / [double]($w - 32) * $span)
      if ($secAt -lt 0) { $secAt = 0 }
      if ($secAt -gt 86399) { $secAt = 86399 }
      $at = $dayStart.AddSeconds($secAt)
      $txt = $at.ToString('HH:mm')
      if ($hoverSeg) {
        $hs = [datetime]::Parse($hoverSeg.s); $he = [datetime]::Parse($hoverSeg.e)
        $txt = "$($hs.ToString('HH:mm:ss')) – $($he.ToString('HH:mm:ss'))   $(Format-HM ([int]$hoverSeg.sec))"
      }
      if ($hoverOff) {
        $txt = "离线 " + $hoverOff.s.ToString('HH:mm:ss') + ' – ' + $hoverOff.e.ToString('HH:mm:ss') + '   ' + (Format-HM ([int]$hoverOff.sec))
      }
      $btxt = New-Object System.Drawing.SolidBrush $script:UiText
      $tw = $g.MeasureString($txt, $script:FTiny).Width
      $tx = $hoverX + 6
      if ($tx + $tw -gt ($w - 8)) { $tx = $hoverX - 6 - $tw }
      $g.DrawString($txt, $script:FTiny, $btxt, [single]$tx, [single]($baseY - 22))
      $btxt.Dispose()
    }
    for ($hr = 0; $hr -le 24; $hr += 6) {
      $x = 16 + $hr / 24.0 * ($w - 32)
      $pen = New-Object System.Drawing.Pen $script:UiLine, 1
      $g.DrawLine($pen, [single]$x, [single]($baseY + 18), [single]$x, [single]($baseY + 22))
      $pen.Dispose()
      $btxt = New-Object System.Drawing.SolidBrush $script:UiMuted
      $g.DrawString("$hr", $script:FTiny, $btxt, ([single]($x - 4)), [single]($baseY + 23))
      $btxt.Dispose()
    }
  }
}

function Show-Panel($state, [datetime]$now) {
  try {
    Initialize-WinForms
    if ($script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close() }
    $script:PanelRange = 0
    $script:PanelReady = $false
    $script:PanelHoverX = -1
    $script:PanelHoverY = -1
    $script:PanelHold = $false
    $script:PanelSig = ''
    # 高度跟着内容走：程序列出来才发现空一大块很难看
    $w = 520
    $h = Get-ScreenPanelHeight $state $now 0
    $f = New-Object System.Windows.Forms.Form
    Set-PanelDoubleBuffer $f
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = $script:UiBg
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ClientSize = New-Object System.Drawing.Size $w, $h
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Location = New-Object System.Drawing.Point (($wa.Right - $w - 10), ($wa.Bottom - $h - 10))
    $f.Add_Paint({ param($s, $e) Draw-Panel $e.Graphics $s.ClientSize.Width $s.ClientSize.Height })
    $f.Add_MouseClick({
      param($s, $e)
      $cr = $script:PanelCloseRect
      if ($cr -and $e.X -ge $cr.x -and $e.X -le ($cr.x + $cr.w) -and $e.Y -ge $cr.y -and $e.Y -le ($cr.y + $cr.h)) { $s.Close(); return }
      $tr = $script:PanelToggleRect
      if ($tr -and $e.X -ge $tr.x -and $e.X -le ($tr.x + $tr.w) -and $e.Y -ge $tr.y -and $e.Y -le ($tr.y + $tr.h)) {
        Set-OfflineMode $script:State (-not [bool]$script:State.offline) (Get-Date)
        Save-State $script:State
        # -Panel 模式没有托盘图标，别在这里炸掉（曾导致面板切换后不重画）
        if ($script:Ni) { $script:Ni.Text = Get-TooltipText $script:State (Get-Date) }
        $s.Invalidate()
        return
      }
      $script:PanelReady = $true
      foreach ($t in $script:TabRects) {
        if ($e.Y -ge 8 -and $e.Y -le 34 -and $e.X -ge $t.x -and $e.X -le ($t.x + $t.w + 8)) {
          $script:PanelRange = $t.i
          # 高度跟着这一栏的程序条数走，不然切到近 7 天时最后一行会跟柱子挤在一起
          $nh = Get-ScreenPanelHeight $script:State (Get-Date) $t.i
          $s.ClientSize = New-Object System.Drawing.Size 520, $nh
          $wa2 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
          $s.Location = New-Object System.Drawing.Point (($wa2.Right - 520 - 10), ($wa2.Bottom - $nh - 10))
          $s.Invalidate()
          return
        }
      }
    })
    # 鼠标停在时间轴上：高亮压到的那一段，并显示精确的起止时间
    $f.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:PanelHold = $true } })
    $f.Add_MouseUp({ param($s, $e) $script:PanelHold = $false })
    $f.Add_MouseMove({
      param($s, $e)
      $x = [int]$e.X
      $y = [int]$e.Y
      if ($x -ne [int]$script:PanelHoverX -or $y -ne [int]$script:PanelHoverY) {
        $script:PanelHoverX = $x
        $script:PanelHoverY = $y
        $s.Invalidate()
      }
    })
    $f.Add_MouseLeave({
      param($s, $e)
      if ([int]$script:PanelHoverX -ne -1 -or [int]$script:PanelHoverY -ne -1) {
        $script:PanelHoverX = -1
        $script:PanelHoverY = -1
        $s.Invalidate()
      }
    })
    # 点别处就收起来。但不能立刻武装：菜单刚关掉时也会触发一次 Deactivate，
    # 那时候就关掉的话用户什么都看不到。所以延迟半秒再开始响应。
    # 计时器存在 script 作用域里，不用闭包变量——闭包里的变量在外部作用域销毁后会变成 null。
    $f.Add_Shown({
      $script:PanelArm = New-Object System.Windows.Forms.Timer
      $script:PanelArm.Interval = 500
      $script:PanelArm.Add_Tick({ $script:PanelArm.Stop(); $script:PanelReady = $true })
      $script:PanelArm.Start()
    })
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape' -or $e.KeyCode -eq 'Space') { $s.Close() } })
    # 关闭方式：**只有点到面板外面才关**。以前挂在 Deactivate 上，一切换焦点就关，
    # 想看一眼、截个图都来不及。这里每 20 毫秒看一眼鼠标左键是不是按在面板外。
    $script:PanelWatch = New-Object System.Windows.Forms.Timer
    $script:PanelWatch.Interval = 20
    $script:PanelWatch.Add_Tick({
      try {
        if (-not $script:PanelForm -or $script:PanelForm.IsDisposed) { $script:PanelWatch.Stop(); return }
        $r = $script:PanelForm.RectangleToScreen($script:PanelForm.ClientRectangle)
        $pos = [System.Windows.Forms.Cursor]::Position
        $inside = ($pos.X -ge $r.Left -and $pos.X -le $r.Right -and $pos.Y -ge $r.Top -and $pos.Y -le $r.Bottom)
        # 别的工具后来开了明细面板，就先把我的收起来，只留一个
        try {
          $ownerFile = Join-Path $env:TEMP 'dsh-tray-panel.owner'
          if (Test-Path $ownerFile) {
            $parts = (Get-Content $ownerFile -Raw -ErrorAction SilentlyContinue).Trim() -split '\|'
            if ($parts.Count -eq 2 -and $parts[0] -ne 'screen-time-counter') {
              if ([long]$parts[1] -gt [long]$script:PanelOpenedAt) { $script:PanelForm.Close(); return }
            }
          }
        } catch {}
        # 每 100 次心跳（约 2 秒）核一次内容：只有画出来的东西真的变了才重画。
        # 面板上的数字都按分钟显示，一分钟才跳一次；固定每 2 秒重画纯粹是白画。
        # 程序行跟着 30 秒的心跳换，换程序时这里也立刻看得出来。
        $script:PanelTickN = [int]$script:PanelTickN + 1
        if (($script:PanelTickN % 100) -eq 0) {
          $nowP = Get-Date
          $rngP = [int]$script:PanelRange
          if ($rngP -eq 2) {
            $secP = [int64](Get-RangeSeconds $script:State $nowP 7)
            $funP = [int64](Get-RangeFun $script:State $nowP 7)
            $offP = [int64](Get-RangeOffline $script:State $nowP 7)
          } else {
            $dP = $nowP.AddDays(-$rngP)
            $secP = [int64](Get-DaySeconds $script:State $dP)
            $funP = [int64](Get-DayFun $script:State $dP)
            $offP = [int64](Get-DayOffline $script:State $dP)
          }
          $sigP = "$rngP|" + (Format-HM $secP) + "|" + (Format-HM $funP) + "|" + (Format-HM $offP) + "|" + [bool]$script:State.offline + "|"
          if ($rngP -ne 2) {
            # 今天/昨天底下画的是 24 小时时间轴：段的条数或当前段的起点变了，也得重画
            $sigP += [string]$script:State.current + '|'
            if ($script:State.PSObject.Properties['live'] -and $script:State.live) { $sigP += [string]$script:State.live.e + '|' }
            $kP = Get-DayKey $dP
            if ($script:State.days.PSObject.Properties[$kP]) { $sigP += [string]@($script:State.days.$kP.segments).Count + '|' }
          }
          foreach ($ap in @(Get-PanelApps $script:State $nowP $rngP)) { $sigP += $ap.n + ':' + (Format-HM ([int64]$ap.v)) + '/' + (Format-HM ([int64]$ap.o)) + ';' }
          if ($sigP -ne [string]$script:PanelSig) { $script:PanelSig = $sigP; $script:PanelForm.Invalidate() }
        }
        # 任务栏/托盘那一带不算「点到别处」：不然点托盘图标开面板时，按下的那一刻就被
        # 判成点在面板外，面板先关一次再被点开，看着就是「闪一下又弹出来」。
        $waNow = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $onTaskbar = ($pos.Y -gt $waNow.Bottom -or $pos.Y -lt $waNow.Top -or $pos.X -gt $waNow.Right -or $pos.X -lt $waNow.Left)
        $downNow = ([ScreenTimeUi.Keys]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
        if (-not $downNow) { $script:PanelHold = $false }
        # 在面板里按下去再拖到面板外松手不算「点别处」，否则拖滚动条手滑出边界就会把面板关掉
        if (-not $inside -and -not $onTaskbar -and -not $script:PanelHold -and $downNow) {
          $script:PanelForm.Close()
        }
      } catch {}
    })
    $script:PanelWatch.Start()
    $script:PanelTickN = 0
    $script:PanelForm = $f
    # 三个工具的明细面板同一时刻只留一个，别在右下角叠成一摞
    $script:PanelOpenedAt = [DateTime]::UtcNow.Ticks
    try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'dsh-tray-panel.owner'), "screen-time-counter|$($script:PanelOpenedAt)") } catch {}
    $f.Show()
    $f.Activate()
  } catch { Write-Log "面板打开失败：$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)" }
}

function Update-Tray {
  try {
    $now = Get-Date
    # 挂起检测：两次心跳隔了太久，说明中间机器睡了或被冻住，那段时间不算
    if ($script:State.current -and $script:State.lastTick) {
      $last = [datetime]::Parse($script:State.lastTick)
      if (($now - $last).TotalSeconds -gt ($script:IntervalSec * 3)) {
        Write-Log "检测到挂起：上次心跳 $($last.ToString('HH:mm:ss'))，现在 $($now.ToString('HH:mm:ss'))"
        Close-Segment $script:State $last
        if ($script:DisplayOn) { Start-Segment $script:State $now }
      }
    }
    # 注意：这里**不要**加「空闲超过灭屏时间就当成屏幕灭了」的兜底。
    # 实测过：这台机器上屏幕并不按设置的 5 分钟自动灭（DSH 持有 AWAYMODE 请求，
    # 音频驱动也占着），空闲涨到 262 秒屏幕照样是亮的。按空闲判会把你长时间
    # 看文章、看视频的过程错误地切成好几段。屏幕灭不灭只信系统通知。
    # 把收到的电源广播原样记进日志，方便判断这台机器到底发的是哪种
    $lb = [ScreenTimeWatch]::LastBroadcast
    if ($lb -and $lb -ne $script:LastBroadcast) {
      Write-Log "电源广播：$lb"
      $script:LastBroadcast = $lb
    }
    # 前台程序换了就把上一段应用时间结算掉。
    # 判断统一走 Test-ShouldSkipApp：不该记的前台窗口保持上一个归属，不结算。
    if ($script:State.current) {
      $fgPid = [ScreenTimeWatch]::ForegroundPid()
      $fgNow = [ScreenTimeWatch]::ForegroundApp()
      if (-not (Test-ShouldSkipApp $fgPid $fgNow)) {
        if (-not $script:AppStart) {
          Start-AppSlice $script:State $now
        } elseif ($fgNow -ne $script:AppName) {
          Close-AppSlice $script:State $now
          Start-AppSlice $script:State $now
        }
      }
    }
    $sec = Get-DayWork $script:State $now
    if ($sec -ne $script:LastSec) { $script:Ni.Icon = New-TimeIcon $sec; $script:LastSec = $sec }
    $script:Ni.Text = Get-TooltipText $script:State $now
    Save-State $script:State
  } catch { Write-Log "心跳失败：$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)" }
}

# 有人在自己文件夹里放一个 exit-request.txt，就正常退出：先结算当前这一段、存盘，删掉请求文件，再关。
# 这样以后重启和更新都不用强杀进程（强杀会丢上一次存盘之后的那一段）。
function Test-ExitRequested {
  $flag = Join-Path $Root 'exit-request.txt'
  if (-not (Test-Path $flag)) { return $false }
  try { Remove-Item $flag -Force -ErrorAction SilentlyContinue } catch {}
  Write-Log 'exit requested by flag file'
  $script:Timer.Stop()
  Close-Segment $script:State (Get-Date)
  Save-State $script:State
  $script:Ni.Visible = $false; $script:Ni.Dispose()
  [System.Windows.Forms.Application]::Exit()
  return $true
}

function Start-Tray {
  Initialize-WinForms
  $script:LastSec = -1
  $script:Ni = New-Object System.Windows.Forms.NotifyIcon
  $script:Ni.Icon = New-TimeIcon 0
  $script:Ni.Text = '屏幕时间 启动中'
  $script:Ni.Visible = $true

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miDetail = $menu.Items.Add('明细')
  $miNow    = $menu.Items.Add('立即刷新')
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $miOpen   = $menu.Items.Add('打开所在文件夹')
  $miExit   = $menu.Items.Add('退出')
  $script:Ni.ContextMenuStrip = $menu

  # 左键单击托盘图标当开关用：点一下开，再点一下关。
  # （鼠标按在托盘那一片不算「点到面板外」，所以不会被外面的规则先关掉。）
  $script:Ni.Add_MouseClick({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    try {
      if ($script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close(); return }
      Update-Tray
      Show-Panel $script:State (Get-Date)
    } catch { Write-Log "left click failed: $($_.Exception.Message)" }
  })

  $miDetail.Add_Click({ Update-Tray; Show-Panel $script:State (Get-Date) })
  $miNow.Add_Click({ Update-Tray })
  $miOpen.Add_Click({ Start-Process explorer.exe $Root })
  $miExit.Add_Click({
    $script:Timer.Stop()
    Close-Segment $script:State (Get-Date)
    Save-State $script:State
    $script:Ni.Visible = $false; $script:Ni.Dispose()
    [System.Windows.Forms.Application]::Exit()
  })

  # 屏幕亮灭：系统会通过电源通知送过来。0 = 灭，1 = 亮，2 = 变暗（按亮处理）
  $script:Watch = New-Object ScreenTimeWatch
  if (-not $script:Watch.Registered) { Write-Log "警告：显示器电源通知注册失败，屏幕灭掉可能收不到" }
  [ScreenTimeWatch]::OnDisplayChanged = {
    param([int]$state)
    try {
      $now = Get-Date
      $script:NotifSeen = $true
      Write-Log "收到显示器通知：$state（空闲 $([ScreenTimeWatch]::IdleSeconds()) 秒）"
      if ($state -eq 0) {
        Close-Segment $script:State $now
        $script:DisplayOn = $false
      } else {
        if (-not $script:DisplayOn) { Start-Segment $script:State $now }
        $script:DisplayOn = $true
      }
      Update-Tray
    } catch { Write-Log "处理显示器通知出错：$($_.Exception.Message)" }
  }

  $script:Timer = New-Object System.Windows.Forms.Timer
  $script:Timer.Interval = [int]($script:IntervalSec * 1000)
  $script:Timer.Add_Tick({ if (Test-ExitRequested) { return }; Update-Tray })
  $script:Timer.Start()

  Write-Log "托盘启动，版本 $ToolVersion，心跳 $($script:IntervalSec) 秒。规则：屏幕亮着就算，灭了就停。"
  Update-Tray
  [System.Windows.Forms.Application]::Run()
}

# ---------------------------------------------------------------- 入口

$state = Load-State
# 状态读不出来时，先试着用上一次的备份救回来
if ($null -eq $state -and (Test-Path $BakPath)) {
  try {
    $bak = Get-Content $BakPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($bak -and $bak.PSObject.Properties['days']) {
      $state = $bak
      Write-Log 'state.json 不在或读不了 -> 用 state.bak.json 恢复'
    }
  } catch { Write-Log "备份也读不了：$($_.Exception.Message)" }
}
if ($null -eq $state) { $state = New-State }
# 每次启动留一份上一版的备份。只在这份确实有记录时才覆盖，免得把好备份冲成空的。
if ((Test-Path $StatePath) -and (@($state.days.PSObject.Properties).Count -gt 0)) {
  try { Copy-Item -Path $StatePath -Destination $BakPath -Force } catch { Write-Log "备份失败：$($_.Exception.Message)" }
}

$script:State = $state
# 离线是手动开关，进程重启后继续按存档状态走；没记起点就从现在开始算
if ($script:State.offline -and -not $script:State.offlineFrom) { $script:State.offlineFrom = (Get-Date).ToString('o') }
$script:IntervalSec = $IntervalSec
$script:AppName = $null
$script:AppStart = $null
$script:FunApps = Get-FunApps
$script:SkipApps = Get-SkipApps
$script:HostApps = Get-HostApps
$script:NotifSeen = $false
$script:LastBroadcast = ""
$script:TimeoutSec = Get-MonitorTimeoutSec
# 启动时先猜一下屏幕状态，第一个系统通知到来后会纠正
$script:DisplayOn = Get-DisplayOnGuess

# 诊断模式只读，不改状态、不留记录
if ($Once) {
  $now = Get-Date
  "今天：$(Format-HM (Get-DaySeconds $state $now))，共 $(Get-DaySegmentCount $state $now) 段"
  "昨天：$(Format-HM (Get-DaySeconds $state $now.AddDays(-1)))"
  "屏幕：$(if ($script:DisplayOn) { '亮着' } else { '灭着' })   当前空闲 $([ScreenTimeWatch]::IdleSeconds()) 秒"
  "离线模式：$(if ($state.offline) { '开' } else { '关' })   今天离线 $(Format-HM (Get-DayOffline $state $now))   今天办公 $(Format-HM (Get-DayWork $state $now))"
  # 互斥体被占用就说明托盘在跑，这个判断不会误伤自己
  $probe = New-Object System.Threading.Mutex($false, 'Local\screen-time-counter-singleton')
  $busy = -not $probe.WaitOne(0, $false)
  if (-not $busy) { $probe.ReleaseMutex() }
  "托盘在跑吗：$(if ($busy) { '是' } else { '否' })"
  "提示文本 $((Get-TooltipText $state $now).Length)/63"
  exit 0
}
if ($Detail) {
  (Get-DetailText $state (Get-Date))
  exit 0
}

# 回填：必须先把托盘退掉，否则它每 30 秒会用自己的内存状态覆盖掉回填结果
if ($Backfill) {
  $probe = New-Object System.Threading.Mutex($false, 'Local\screen-time-counter-singleton')
  $busy = -not $probe.WaitOne(0, $false)
  if (-not $busy) { $probe.ReleaseMutex() }
  if ($busy) { "托盘正在运行。先右键退出，再回填，否则它会把回填覆盖掉。"; exit 1 }
  $n = Invoke-Backfill $state (Get-Date) $BackfillDays
  Save-State $state
  "回填完成：最近 $BackfillDays 天共补了 $([math]::Round($n / 3600, 1)) 小时"
  exit 0
}

# 只看面板：加载状态、把窗口打开、跑消息循环，不碰互斥体也不改记录
if ($Panel) {
  $script:State = $state
  $script:FunApps = Get-FunApps
  Show-Panel $state (Get-Date)
  $t = New-Object System.Windows.Forms.Timer
  $t.Interval = 400
  $t.Add_Tick({
    if (-not $script:PanelForm -or $script:PanelForm.IsDisposed) { $t.Stop(); [System.Windows.Forms.Application]::Exit() }
  })
  $t.Start()
  [System.Windows.Forms.Application]::Run()
  exit 0
}

# 单实例检查必须放在任何状态修改之前：否则第二个实例会先把状态改一遍再退出
$script:SingleInstance = New-Object System.Threading.Mutex($false, 'Local\screen-time-counter-singleton')
if (-not $script:SingleInstance.WaitOne(0, $false)) {
  Write-Log "已经有一个在跑了，这个退出"
  exit 0
}

# 上次没正常退出的残留：用最后心跳时间收尾，免得把离线时间算进去。
# 先把上次正在计的那个程序恢复出来，这样它的时间也能一起结算，不会丢。
if ($state.PSObject.Properties['appName'] -and $state.appName -and $state.PSObject.Properties['appStart'] -and $state.appStart) {
  $script:AppName  = $state.appName
  $script:AppStart = [datetime]::Parse($state.appStart)
}
if ($state.current) {
  $end = if ($state.lastTick) { [datetime]::Parse($state.lastTick) } else { [datetime]::Parse($state.current) }
  # state.json 坏了会退回旧备份，lastTick 也跟着退回昨天。追加日志里记着「正在计的这一段的起点」，
  # 起点对得上就说明是同一次会话，可以放心把结束时间推进到日志最后一条，最多丢一个心跳（30 秒）。
  $j = Get-JournalLast
  if ($j -and $j.current -and $j.current -eq $state.current -and $j.at -gt $end) {
    $end = $j.at
    Write-Log "用追加日志把这段补到 $($end.ToString('HH:mm:ss'))"
  }
  Close-Segment $state $end
  Write-Log "发现上次未收尾的记录，已按最后心跳时间收在 $($end.ToString('HH:mm:ss'))"
} elseif ($j = Get-JournalLast) {
  # 存档里没有未收尾的段（常见于 state.json 坏了、退回到更早的备份），
  # 但追加日志里还留着「正在计的这一段」的起点：起点在一天内就把它补回来。
  if ($j.current) {
    $cs = [datetime]::Parse($j.current)
    if ($j.at -gt $cs -and ((Get-Date) - $j.at).TotalHours -lt 24) {
      $state | Add-Member -NotePropertyName current -NotePropertyValue $j.current -Force
      Close-Segment $state $j.at
      Write-Log "存档里没有未收尾的段，用追加日志补回 $($cs.ToString('HH:mm:ss')) -> $($j.at.ToString('HH:mm:ss'))"
    }
  }
}
$script:AppName = $null
$script:AppStart = $null
# 收尾之后把心跳时间对齐到现在，否则第一个心跳会把刚起的这一段当成「挂起」
$state.lastTick = (Get-Date).ToString('o')
if ($script:DisplayOn) { Start-Segment $state (Get-Date) }

Start-Tray
