# screen-time-counter - 屏幕点亮时长计数器
# 版本 1.0
#
# 记录屏幕真正亮着的时长。规则一句话：
#   只要距离最后一次键盘/鼠标动作不超过 5 分钟，就算在用；超过了就不算。
# 依据：系统设置是空闲 5 分钟灭屏、15 分钟睡眠，所以灭屏本身就代表「已经 5 分钟没动」。
# 看视频时系统会保持屏幕点亮，不受这条影响。
#
# 屏幕开关由系统的「显示器电源状态」通知驱动（GUID_CONSOLE_DISPLAY_STATE），是事件而不是猜。
# 一段结束（灭屏 / 退出 / 检测到挂起）时，从「最后一次输入」到结束那一刻的时间会被扣掉。

param(
  [switch]$Once,        # 控制台模式：算一次并打印，然后退出
  [switch]$Detail,      # 控制台模式：打印明细文本后退出
  [switch]$Panel,       # 只把面板窗口打开（不启动托盘），方便看效果
  [switch]$Backfill,    # 用系统日志回填最近几天工具还没运行的时间
  [int]$BackfillDays = 7,
  [int]$IntervalSec = 30
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $Root 'state.json'
$LogPath   = Join-Path $Root 'screen-time.log'
$CatPath   = Join-Path $Root 'categories.json'

function Write-Log([string]$m) {
  try { Add-Content -Path $LogPath -Value ("{0}  {1}" -f (Get-Date).ToString('o'), $m) -Encoding UTF8 } catch {}
}

# ---------------------------------------------------------------- 系统接口

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

# 某一天按程序分的行（含正在进行的那个程序）
function Get-DayAppRows($state, $d) {
  $k = Get-DayKey $d
  $rows = @()
  if ($state.days.PSObject.Properties[$k] -and $state.days.$k.PSObject.Properties['apps']) {
    foreach ($p in @($state.days.$k.apps.PSObject.Properties)) { $rows += [pscustomobject]@{ n = $p.Name; v = [int64]$p.Value } }
  }
  if ($script:AppStart -and $script:AppName -and (Get-DayKey $script:AppStart) -eq $k) {
    $live = [int][Math]::Round((New-TimeSpan -Start $script:AppStart -End (Get-Date)).TotalSeconds)
    $found = $false
    foreach ($r in $rows) { if ($r.n -eq $script:AppName) { $r.v += $live; $found = $true } }
    if (-not $found) { $rows += [pscustomobject]@{ n = $script:AppName; v = [int64]$live } }
  }
  return $rows
}

function Get-DayFun($state, $d) {
  $sum = [int64]0
  foreach ($r in (Get-DayAppRows $state $d)) { if (Test-FunApp $r.n) { $sum += [int64]$r.v } }
  return $sum
}

# 办公时长 = 屏幕时长 − 娱乐程序的时长（不小于 0）
function Get-DayWork($state, $d) {
  $w = [int64](Get-DaySeconds $state $d) - [int64](Get-DayFun $state $d)
  if ($w -lt 0) { $w = 0 }
  return $w
}

function New-State {
  [pscustomobject]@{
    keyVersion  = 1
    days        = [pscustomobject]@{}
    current     = $null      # 正在计时的那一段的开始时间
    lastTick    = $null
  }
}

function Load-State {
  if (-not (Test-Path $StatePath)) { return $null }
  try {
    $s = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $s.PSObject.Properties['days'])    { $s | Add-Member -NotePropertyName days -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $s.PSObject.Properties['current']) { $s | Add-Member -NotePropertyName current -NotePropertyValue $null }
    if (-not $s.PSObject.Properties['lastTick']){ $s | Add-Member -NotePropertyName lastTick -NotePropertyValue $null }
    return $s
  } catch { Write-Log "state.json 读不了，重新开始：$($_.Exception.Message)"; return $null }
}

function Save-State($s) {
  try {
    $s.lastTick = (Get-Date).ToString('o')
    # 正在计的那个程序也存下来：不然进程一旦重启，这段应用时间就丢了
    if (-not $s.PSObject.Properties['appName'])  { $s | Add-Member -NotePropertyName appName  -NotePropertyValue $null }
    if (-not $s.PSObject.Properties['appStart']) { $s | Add-Member -NotePropertyName appStart -NotePropertyValue $null }
    $s.appName  = $script:AppName
    $s.appStart = if ($script:AppStart) { ([datetime]$script:AppStart).ToString('o') } else { $null }
    $tmp = "$StatePath.tmp"
    [System.IO.File]::WriteAllText($tmp, ($s | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $StatePath -Force
  } catch { Write-Log "保存状态失败：$($_.Exception.Message)" }
}

function Ensure-Day($state, $d) {
  $k = Get-DayKey $d
  if (-not $state.days.PSObject.Properties[$k]) {
    $state.days | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{ seconds = 0; segments = @(); apps = [pscustomobject]@{} })
  } elseif (-not $state.days.$k.PSObject.Properties['apps']) {
    $state.days.$k | Add-Member -NotePropertyName apps -NotePropertyValue ([pscustomobject]@{})
  }
  return $k
}

# 把一段时间记到某个程序头上
function Add-AppSeconds($state, [datetime]$at, [string]$name, [int]$sec) {
  if ($sec -lt 1 -or -not $name) { return }
  $k = Ensure-Day $state $at
  $apps = $state.days.$k.apps
  $old = 0
  if ($apps.PSObject.Properties[$name]) { $old = [int64]$apps.$name }
  if ($apps.PSObject.Properties[$name]) { $apps.$name = $old + [int64]$sec }
  else { $apps | Add-Member -NotePropertyName $name -NotePropertyValue ([int64]$sec) }
}

# 应用切片：屏幕亮着的时候，每隔一会儿问一次「现在最前面是哪个程序」，
# 换了就结算上一段，这样时间才能归到具体应用上
function Start-AppSlice($state, [datetime]$at) {
  if (-not $state.current) { return }
  # 本工具自己抢到前台时不算（比如脚本自己的窗口），保持上一个归属
  if ([ScreenTimeWatch]::ForegroundPid() -eq $PID) { return }
  $script:AppName  = [ScreenTimeWatch]::ForegroundApp()
  $script:AppStart = $at
}

function Close-AppSlice($state, [datetime]$at) {
  if (-not $script:AppStart) { return }
  $sec = [int][Math]::Round((New-TimeSpan -Start $script:AppStart -End $at).TotalSeconds)
  Add-AppSeconds $state $script:AppStart $script:AppName $sec
  $script:AppStart = $null
  $script:AppName  = $null
}

# 收尾一段：屏幕灭了（或者程序退出、检测到挂起）就把 [开始, 结束] 整段记下来
# 规则只有一条：屏幕亮着就算，灭了就停。不做任何「人走没走」的判断。
function Close-Segment($state, [datetime]$endAt) {
  if (-not $state.current) { return }
  Close-AppSlice $state $endAt
  $start = [datetime]::Parse($state.current)
  $total = ($endAt - $start).TotalSeconds
  if ($total -lt 0) { $total = 0 }
  $counted = [int][Math]::Round($total)

  if ($counted -ge 1) {
    $k = Ensure-Day $state $start
    $day = $state.days.$k
    $day.seconds = [int64]$day.seconds + [int64]$counted
    $seg = [pscustomobject]@{
      s   = $start.ToString('o')
      e   = $endAt.ToString('o')
      sec = $counted
    }
    # 紧邻的上一段（间隔 60 秒内）合并，免得重启一次就多出一段
    $segs = @($day.segments)
    $merged = $false
    if ($segs.Count -gt 0) {
      $last = $segs[-1]
      if (($start - [datetime]::Parse($last.e)).TotalSeconds -le 60) {
        $last.e   = $endAt.ToString('o')
        $last.sec = [int]$last.sec + $counted
        $day.segments = $segs
        $merged = $true
      }
    }
    if (-not $merged) { $day.segments = @($segs + $seg) }
    Write-Log "记一段 $($start.ToString('HH:mm:ss')) -> $($endAt.ToString('HH:mm:ss'))，$counted 秒$(if($merged){'，已并入上一段'})"
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

# 最近 N 天里，按程序汇总
function Get-RangeApps($state, [datetime]$endDay, [int]$days) {
  $acc = @{}
  for ($i = 0; $i -lt $days; $i++) {
    $k = Get-DayKey $endDay.AddDays(-$i)
    if (-not $state.days.PSObject.Properties[$k]) { continue }
    if (-not $state.days.$k.PSObject.Properties['apps']) { continue }
    foreach ($p in @($state.days.$k.apps.PSObject.Properties)) {
      if (-not $acc.ContainsKey($p.Name)) { $acc[$p.Name] = [int64]0 }
      $acc[$p.Name] += [int64]$p.Value
    }
  }
  return $acc
}

# ---------------------------------------------------------------- 显示

function Format-HM([int]$sec) {
  if ($sec -le 0) { return '0 秒' }
  if ($sec -lt 60) { return "$sec 秒" }
  $h = [int]($sec / 3600); $m = [int](($sec % 3600) / 60)
  if ($h -gt 0 -and $m -gt 0) { return "$h 小时 $m 分" }
  if ($h -gt 0) { return "$h 小时" }
  return "$m 分"
}

function Get-DaySeconds($state, $d) {
  $k = Get-DayKey $d
  $base = [int64]0
  if ($state.days.PSObject.Properties[$k]) { $base = [int64]$state.days.$k.seconds }
  $live = 0
  # 正在计时的那一段也算进去（末尾的空闲要等收尾时才扣）
  if ($state.current) {
    $start = [datetime]::Parse($state.current)
    if ((Get-DayKey $start) -eq $k) {
      $live = [int](New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds
      if ($live -lt 0) { $live = 0 }
    }
  }
  return $base + [int64]$live
}

function Get-DaySegmentCount($state, $d) {
  $k = Get-DayKey $d
  $n = 0
  if ($state.days.PSObject.Properties[$k]) { $n = @($state.days.$k.segments).Count }
  if ($state.current -and (Get-DayKey ([datetime]::Parse($state.current))) -eq $k) { $n++ }
  return $n
}

function New-TimeIcon([int]$sec) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 200, 110, 0))), 0, 0, 31, 31)
  $h = [int]($sec / 3600); $m = [int](($sec % 3600) / 60)
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
  $yw   = Get-DayWork $state $now.AddDays(-1)
  $line = "今天：办公 $(Format-HM $work)"
  if ($fun -gt 0) { $line += "`n娱乐 $(Format-HM $fun)" }
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
    $workSec = [int64]$sec - [int64]$funSec
    if ($workSec -lt 0) { $workSec = 0 }
    $cnt = Get-DaySegmentCount $state $d
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("【$label】$k")
    $max3 = [Math]::Max($workSec, $funSec)
    [void]$sb.AppendLine(("    办公 " + (Format-HM $workSec).PadLeft(13) + "  " + (Format-Bar $workSec $max3)))
    [void]$sb.AppendLine(("    娱乐 " + (Format-HM $funSec).PadLeft(13) + "  " + (Format-Bar $funSec $max3)))
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
    if ($state.current -and (Get-DayKey ([datetime]::Parse($state.current))) -eq $k) {
      $s0 = [datetime]::Parse($state.current)
      [void]$sb.AppendLine("    $($s0.ToString('HH:mm')) – 现在" + "（还在算）".PadLeft(11))
    }
    # 按程序分（娱乐的标出来）
    $rows = Get-DayAppRows $state $d
    if ($rows.Count -gt 0) {
      $sorted = @($rows | Sort-Object -Property @{Expression='v';Descending=$true})
      $maxApp = 0
      foreach ($r in $sorted) { if ([int64]$r.v -gt $maxApp) { $maxApp = [int64]$r.v } }
      [void]$sb.AppendLine('    按程序分：')
      foreach ($r in $sorted) {
        $tagApp = if (Test-FunApp $r.n) { ' 娱乐' } else { '' }
        [void]$sb.AppendLine("      " + $r.n.PadRight(18) + (Format-HM $r.v).PadLeft(12) + "  " + (Format-Bar $r.v $maxApp) + $tagApp)
      }
    }
  }
  # 最后才是近 7 天：今天和昨天放前面
  $r7 = Get-RangeSeconds $state $now 7
  $f7 = Get-RangeFun $state $now 7
  $w7 = [int64]$r7 - [int64]$f7
  if ($w7 -lt 0) { $w7 = 0 }
  $from7 = $now.Date.AddDays(-6).ToString('MM-dd')
  $to7   = $now.Date.ToString('MM-dd')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("【近 7 天】$from7 ~ $to7")
  $max7 = [Math]::Max($w7, $f7)
  [void]$sb.AppendLine(("    办公 " + (Format-HM $w7).PadLeft(13) + "  " + (Format-Bar $w7 $max7)))
  [void]$sb.AppendLine(("    娱乐 " + (Format-HM $f7).PadLeft(13) + "  " + (Format-Bar $f7 $max7)))
  [void]$sb.AppendLine(("    合计 " + (Format-HM $r7).PadLeft(13)))
  $apps7 = Get-RangeApps $state $now 7
  $top = @()
  foreach ($n in $apps7.Keys) { $top += [pscustomobject]@{ n = $n; v = $apps7[$n] } }
  if ($script:AppStart -and $script:AppName) {
    $live = [int][Math]::Round((New-TimeSpan -Start $script:AppStart -End (Get-Date)).TotalSeconds)
    $found = $false
    foreach ($t in $top) { if ($t.n -eq $script:AppName) { $t.v += $live; $found = $true } }
    if (-not $found) { $top += [pscustomobject]@{ n = $script:AppName; v = [int64]$live } }
  }
  if ($top.Count -gt 0) {
    $top5 = @($top | Sort-Object -Property @{Expression='v';Descending=$true} | Select-Object -First 5)
    $maxTop = 0
    foreach ($t in $top5) { if ([int64]$t.v -gt $maxTop) { $maxTop = [int64]$t.v } }
    [void]$sb.AppendLine('    用得最多的前 5 个：')
    $rank = 0
    foreach ($t in $top5) {
      $rank++
      $tagT = if (Test-FunApp $t.n) { ' 娱乐' } else { '' }
      [void]$sb.AppendLine("      $rank. " + $t.n.PadRight(16) + (Format-HM $t.v).PadLeft(12) + "  " + (Format-Bar $t.v $maxTop) + $tagT)
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
$script:UiTrack = [System.Drawing.Color]::FromArgb(255, 232, 236, 241)
$script:UiLine  = [System.Drawing.Color]::FromArgb(255, 222, 227, 233)

function Get-UiFonts {
  if (-not $script:FTitle) {
    $script:FTitle = New-Object System.Drawing.Font 'Microsoft YaHei UI', 21, ([System.Drawing.FontStyle]::Bold)
    $script:FTab   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5
    $script:FTabB  = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5, ([System.Drawing.FontStyle]::Bold)
    $script:FSub   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $script:FApp   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $script:FTiny  = New-Object System.Drawing.Font 'Microsoft YaHei UI', 7.5
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
    foreach ($n in $map.Keys) { $rows += [pscustomobject]@{ n = $n; v = [int64]$map[$n] } }
  } else {
    $rows = @(Get-DayAppRows $st $now.AddDays(-$rng))
  }
  if ($script:AppStart -and $script:AppName -and $rng -ne 1) {
    $live = [int][Math]::Round((New-TimeSpan -Start $script:AppStart -End (Get-Date)).TotalSeconds)
    $found = $false
    foreach ($r in $rows) { if ($r.n -eq $script:AppName) { $r.v += $live; $found = $true } }
    if (-not $found) { $rows += [pscustomobject]@{ n = $script:AppName; v = [int64]$live } }
  }
  return @($rows | Sort-Object -Property @{Expression='v';Descending=$true} | Select-Object -First 6)
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
  } else {
    $d = $now.AddDays(-$rng)
    $label = if ($rng -eq 0) { '今天' } else { '昨天' }
    $sec    = [int64](Get-DaySeconds $st $d)
    $funSec = [int64](Get-DayFun $st $d)
  }
  $workSec = $sec - $funSec
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

  # ---- 大字号时长
  $big = (Format-HM $sec)
  $bBig = New-Object System.Drawing.SolidBrush $script:UiText
  $g.DrawString($big, $script:FTitle, $bBig, 14, 44)
  $szBig = $g.MeasureString($big, $script:FTitle)
  $bSub = New-Object System.Drawing.SolidBrush $script:UiMuted
  $g.DrawString("办公 $(Format-HM $workSec)   ·   娱乐 $(Format-HM $funSec)", $script:FSub, $bSub, 18, 40 + $szBig.Height)

  # ---- 办公 / 娱乐 占比条
  $barY = 118; $barX = 16; $barW = $w - 32; $barH = 12
  $gp = New-RoundRect $barX $barY $barW $barH 6
  $tb = New-Object System.Drawing.SolidBrush $script:UiTrack
  $g.FillPath($tb, $gp); $tb.Dispose(); $gp.Dispose()
  if ($sec -gt 0) {
    $wW = [single]($barW * $workSec / $sec)
    if ($wW -gt 0) {
      $gp = New-RoundRect $barX $barY $wW $barH 6
      $b = New-Object System.Drawing.SolidBrush $script:UiWork
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
    if ($funSec -gt 0) {
      $gp = New-RoundRect ($barX + $wW) $barY ([single]($barW - $wW)) $barH 6
      $b = New-Object System.Drawing.SolidBrush $script:UiFun
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
    foreach ($r in $top) { if ($r.v -gt $maxA) { $maxA = [int64]$r.v } }
    foreach ($r in $top) {
      $col = if (Test-FunApp $r.n) { $script:UiFun } else { $script:UiWork }
      $nm = $r.n
      if ($nm.Length -gt 14) { $nm = $nm.Substring(0, 13) + '…' }
      $g.DrawString($nm, $script:FApp, $bTitle, 16, $y)
      $bx = 132; $bw = 200; $bh = 9
      $gp = New-RoundRect $bx ($y + 3) $bw $bh 4
      $b = New-Object System.Drawing.SolidBrush $script:UiTrack
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      $wv = [single]($bw * $r.v / $maxA)
      if ($wv -gt 0) {
        $gp = New-RoundRect $bx ($y + 3) $wv $bh 4
        $b = New-Object System.Drawing.SolidBrush $col
        $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      }
      $bDur = New-Object System.Drawing.SolidBrush $script:UiText
      $g.DrawString((Format-HM $r.v), $script:FApp, $bDur, ($w - 16 - 66), $y)
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
      $v = [int64](Get-DaySeconds $st $dd)
      $vals += [pscustomobject]@{ d = $dd; v = $v }
      if ($v -gt $maxD) { $maxD = $v }
    }
    $i = 0
    foreach ($v in $vals) {
      $bx = 16 + $i * $dayW
      $bh2 = [int](28 * $v.v / $maxD)
      if ($bh2 -lt 1 -and $v.v -gt 0) { $bh2 = 1 }
      $gp = New-RoundRect ($bx + 6) ($baseY + 24 - $bh2) ($dayW - 14) $bh2 3
      $b = New-Object System.Drawing.SolidBrush $(if ($i -eq 6) { $script:UiWork } else { [System.Drawing.Color]::FromArgb(255, 150, 175, 235) })
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      $btxt = New-Object System.Drawing.SolidBrush $script:UiMuted
      $g.DrawString($v.d.ToString('MM-dd'), $script:FTiny, $btxt, ($bx + 2), ($baseY + 26))
      $btxt.Dispose()
      $i++
    }
  } else {
    $d = $now.AddDays(-$rng)
    $k = Get-DayKey $d
    $segs = @()
    if ($st.days.PSObject.Properties[$k]) { $segs = @($st.days.$k.segments) }
    $gp = New-RoundRect 16 $baseY ($w - 32) 16 4
    $b = New-Object System.Drawing.SolidBrush $script:UiTrack
    $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    $dayStart = $d.Date
    $span = 86400.0
    foreach ($sg in $segs) {
      $s0 = [datetime]::Parse($sg.s); $e0 = [datetime]::Parse($sg.e)
      $x1 = 16 + ($s0 - $dayStart).TotalSeconds / $span * ($w - 32)
      $x2 = 16 + ($e0 - $dayStart).TotalSeconds / $span * ($w - 32)
      if ($x2 - $x1 -lt 1.5) { $x2 = $x1 + 1.5 }
      $gp = New-RoundRect ([single]$x1) $baseY ([single]($x2 - $x1)) 16 3
      $b = New-Object System.Drawing.SolidBrush $script:UiWork
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
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
    # 高度跟着内容走：程序列出来才发现空一大块很难看
    $nApp = @(Get-PanelApps $state $now 0).Count
    if ($nApp -lt 1) { $nApp = 1 }
    $w = 420
    $h = 176 + $nApp * 24 + 78
    $f = New-Object System.Windows.Forms.Form
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
      $script:PanelReady = $true
      foreach ($t in $script:TabRects) {
        if ($e.Y -ge 8 -and $e.Y -le 34 -and $e.X -ge $t.x -and $e.X -le ($t.x + $t.w + 8)) {
          $script:PanelRange = $t.i
          $s.Invalidate()
          return
        }
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
    $f.Add_Deactivate({ if ($script:PanelReady -and $script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close() } })
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.Close() } })
    $script:PanelForm = $f
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
    # 前台程序换了就把上一段应用时间结算掉
    if ($script:State.current) {
      $fgPid = [ScreenTimeWatch]::ForegroundPid()
      if ($fgPid -ne $PID) {
        $fg = [ScreenTimeWatch]::ForegroundApp()
        if (-not $script:AppStart) {
          Start-AppSlice $script:State $now
        } elseif ($fg -ne $script:AppName) {
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
  $script:Timer.Add_Tick({ Update-Tray })
  $script:Timer.Start()

  Write-Log "托盘启动，心跳 $($script:IntervalSec) 秒。规则：屏幕亮着就算，灭了就停。"
  Update-Tray
  [System.Windows.Forms.Application]::Run()
}

# ---------------------------------------------------------------- 入口

$state = Load-State
if ($null -eq $state) { $state = New-State }

$script:State = $state
$script:IntervalSec = $IntervalSec
$script:AppName = $null
$script:AppStart = $null
$script:FunApps = Get-FunApps
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
  Close-Segment $state $end
  Write-Log "发现上次未收尾的记录，已按最后心跳时间收在 $($end.ToString('HH:mm:ss'))"
}
$script:AppName = $null
$script:AppStart = $null
if ($script:DisplayOn) { Start-Segment $state (Get-Date) }

Start-Tray
