# MyClicker.ps1
# 정해진 화면 위치를 "한 시간에 한 번", 시간마다 랜덤한 시각에 실제 마우스로 클릭합니다.
# - 마우스 커서가 사람처럼 곡선/가감속으로 이동한 뒤 클릭합니다 (물리 클릭과 동일한 입력).
# - 클릭 시각은 시간 경계 근처(예: 7:58 -> 8:01)에 몰리는 비율이 더 높습니다.
# - 동작 시간 범위는 실행할 때 창에서 정합니다. 창을 닫으면 멈춥니다.
# 이 파일은 한글 UI 때문에 UTF-8(BOM) 으로 저장되어 있습니다. 다른 인코딩으로 저장하지 마세요.

$ErrorActionPreference = 'Stop'

# ===== 랜덤 분포 설정 (원하면 숫자만 바꾸세요) =====
$EDGE_MIN          = 5     # "경계 구간" 길이(분): 시간의 처음 N분 / 마지막 N분
$P_END             = 0.35  # 각 시간에서 마지막 N분(예: 7:55~7:59)에 누를 확률
$P_START           = 0.15  # 각 시간에서 처음 N분(예: 8:00~8:04)에 누를 확률
$P_START_AFTER_END = 0.60  # 직전 클릭이 마지막 N분이었을 때, 이번엔 처음 N분에 누를 확률 (7:58 -> 8:01 패턴)
$MIN_GAP_SEC       = 90    # 연속된 두 클릭 사이 최소 간격(초)
# 나머지 확률은 그 시간 전체(0~59분)에서 균등하게 뽑습니다.

$logDir  = Join-Path $env:LOCALAPPDATA 'MyClicker'
$logFile = Join-Path $logDir 'log.txt'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {

Add-Type @'
using System;
using System.Threading;
using System.Runtime.InteropServices;

public static class HumanMouse
{
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);

    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP   = 0x0004;

    static readonly Random R = new Random();

    public static int[] GetPos()
    {
        POINT p; GetCursorPos(out p);
        return new int[] { p.X, p.Y };
    }

    // Moves the real cursor along a gently curved path with ease-in-out speed.
    public static void MoveTo(int tx, int ty)
    {
        POINT p; GetCursorPos(out p);
        double sx = p.X, sy = p.Y, dx = tx - sx, dy = ty - sy;
        double dist = Math.Sqrt(dx * dx + dy * dy);
        if (dist < 2) { SetCursorPos(tx, ty); return; }

        // Bezier control point pushed sideways by up to 20% of the distance.
        double off = (R.NextDouble() * 0.4 - 0.2) * dist;
        double cx = sx + dx * 0.5 - dy / dist * off;
        double cy = sy + dy * 0.5 + dx / dist * off;

        int totalMs = (int)Math.Min(1300, 250 + dist * 0.5 + R.Next(0, 300));
        int steps = Math.Max(15, totalMs / 10);
        for (int i = 1; i <= steps; i++)
        {
            double t = (double)i / steps;
            double e = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;
            double u = 1 - e;
            double x = u * u * sx + 2 * u * e * cx + e * e * tx;
            double y = u * u * sy + 2 * u * e * cy + e * e * ty;
            SetCursorPos((int)Math.Round(x), (int)Math.Round(y));
            Thread.Sleep(totalMs / steps);
        }
        SetCursorPos(tx, ty);
    }

    public static void LeftClick()
    {
        Thread.Sleep(R.Next(80, 250));            // short pause before pressing, like a person
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(R.Next(60, 140));            // button held down briefly
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }

    // Keeps the PC and the display from sleeping while the clicker is running.
    public static void KeepAwake(bool on)
    {
        // ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1) | ES_DISPLAY_REQUIRED (0x2)
        SetThreadExecutionState(on ? 0x80000003u : 0x80000000u);
    }
}
'@

# 화면 배율(125%, 150% 등)과 상관없이 실제 픽셀 좌표를 쓰도록
[void][HumanMouse]::SetProcessDPIAware()

$rng = New-Object System.Random

# ---------- 상태 ----------
$script:target       = $null    # @(x, y)
$script:running      = $false
$script:nextClick    = $null    # DateTime
$script:nextSlot     = $null    # DateTime (그 시간의 정각)
$script:lastClick    = $null    # DateTime
$script:sessionEnd   = $null    # DateTime (반복 안 할 때 종료 시각)
$script:countdown    = 0

# ---------- 시간 계산 ----------
function Get-HourFloor([datetime]$t) { New-Object DateTime($t.Year, $t.Month, $t.Day, $t.Hour, 0, 0) }

function Test-InRange([int]$h, [int]$startH, [int]$endH) {
    $e = $endH % 24
    if ($startH -eq $e) { return $true }                  # 같으면 하루 종일
    if ($startH -lt $e) { return ($h -ge $startH -and $h -lt $e) }
    return ($h -ge $startH -or $h -lt $e)                 # 자정을 넘는 범위 (예: 22시~2시)
}

# 한 시간 슬롯 안에서 클릭 시각 하나를 뽑음. 경계 근처 비율이 더 높음.
function Get-ClickTime([datetime]$slotStart, [datetime]$lowerBound, [bool]$prevWasEnd) {
    $slotLen = 3600 - 3                                   # 다음 정각 3초 전까지만
    $loSec = [Math]::Max(0, ($lowerBound - $slotStart).TotalSeconds)
    if ($loSec -ge $slotLen - 5) { return $null }

    $edge = $EDGE_MIN * 60
    $pStart = if ($prevWasEnd) { $P_START_AFTER_END } else { $P_START }
    $r = $rng.NextDouble()
    if     ($r -lt $pStart)          { $a = 0;               $b = $edge }
    elseif ($r -lt $pStart + $P_END) { $a = 3600 - $edge;    $b = $slotLen }
    else                             { $a = 0;               $b = $slotLen }

    if ($b -le $loSec + 5) { $a = $loSec; $b = $slotLen }  # 고른 구간이 이미 지났으면 남은 시간 아무 때나
    elseif ($a -lt $loSec) { $a = $loSec }

    $sec = $a + $rng.NextDouble() * ($b - $a)
    return $slotStart.AddSeconds($sec)
}

# minSlot 이후의 첫 번째 "허용된 시간" 슬롯과 그 안의 클릭 시각을 정함.
function Set-NextClick([datetime]$minSlot, [datetime]$lowerBound) {
    $startH = [int]$numStart.Value; $endH = [int]$numEnd.Value
    $slot = Get-HourFloor $minSlot
    for ($i = 0; $i -lt 72; $i++) {
        if ($script:sessionEnd -and $slot -ge $script:sessionEnd) { break }
        if (Test-InRange $slot.Hour $startH $endH) {
            $prevWasEnd = $false
            if ($script:lastClick) {
                $gap = ($slot - $script:lastClick).TotalSeconds
                $prevWasEnd = ($gap -gt 0 -and $gap -le $EDGE_MIN * 60)
            }
            $t = Get-ClickTime $slot $lowerBound $prevWasEnd
            if ($t) {
                $script:nextSlot = $slot
                $script:nextClick = $t
                Write-Log ("다음 클릭 예약: {0:MM-dd HH:mm:ss}  ({1:HH}시대)" -f $t, $slot)
                Update-Status
                return
            }
        }
        $slot = $slot.AddHours(1)
    }
    Write-Log '설정한 시간 범위가 끝났습니다. 자동으로 정지합니다.'
    Stop-Clicker
}

# 반복을 끄면: 지금(또는 다음) 시작되는 범위의 끝에서 정지
function Get-SessionEnd {
    $startH = [int]$numStart.Value; $endH = [int]$numEnd.Value
    $slot = Get-HourFloor (Get-Date)
    $n = 0
    while (-not (Test-InRange $slot.Hour $startH $endH) -and $n -lt 24) { $slot = $slot.AddHours(1); $n++ }
    $n = 0
    while ((Test-InRange $slot.Hour $startH $endH) -and $n -lt 24) { $slot = $slot.AddHours(1); $n++ }
    return $slot
}

# ---------- 로그 ----------
function Write-Log([string]$msg) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $msg
    $lstLog.Items.Insert(0, $line)
    while ($lstLog.Items.Count -gt 500) { $lstLog.Items.RemoveAt($lstLog.Items.Count - 1) }
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd} {1}' -f (Get-Date), $line) -Encoding UTF8
    } catch { }
}

function Update-Status {
    if ($script:running -and $script:nextClick) {
        $left = $script:nextClick - (Get-Date)
        if ($left.TotalSeconds -lt 0) { $left = [TimeSpan]::Zero }
        $lblNext.Text = '다음 클릭: {0:MM-dd HH:mm:ss}   (남은 시간 {1:hh\:mm\:ss})' -f $script:nextClick, $left
    } elseif ($script:running) {
        $lblNext.Text = '다음 클릭: -'
    } else {
        $lblNext.Text = '정지됨'
    }
}

# ---------- 클릭 ----------
function Invoke-HumanClick {
    $j = [int]$numJitter.Value
    $x = $script:target[0] + $rng.Next(-$j, $j + 1)
    $y = $script:target[1] + $rng.Next(-$j, $j + 1)
    $orig = [HumanMouse]::GetPos()
    [HumanMouse]::MoveTo($x, $y)
    [HumanMouse]::LeftClick()
    if ($chkReturn.Checked) {
        Start-Sleep -Milliseconds ($rng.Next(150, 500))
        [HumanMouse]::MoveTo($orig[0], $orig[1])
    }
    return "($x, $y)"
}

function Start-Clicker {
    if (-not $script:target) {
        [System.Windows.Forms.MessageBox]::Show('먼저 [위치 지정] 으로 클릭할 위치를 정해 주세요.', 'MyClicker') | Out-Null
        return
    }
    $script:running = $true
    $script:lastClick = $null
    $script:sessionEnd = if ($chkRepeat.Checked) { $null } else { Get-SessionEnd }
    foreach ($c in @($numStart, $numEnd, $btnPick, $btnStart, $chkRepeat)) { $c.Enabled = $false }
    $btnStop.Enabled = $true
    [HumanMouse]::KeepAwake($true)
    $range = '{0}시 ~ {1}시' -f $numStart.Value, $numEnd.Value
    if ($script:sessionEnd) { $range += (' (오늘 {0:MM-dd HH}시에 종료)' -f $script:sessionEnd) } else { $range += ' (매일 반복)' }
    Write-Log "시작: $range"
    $now = Get-Date
    Set-NextClick $now $now.AddSeconds(10)
    $tick.Start()
}

function Stop-Clicker {
    $tick.Stop()
    $script:running = $false
    $script:nextClick = $null
    [HumanMouse]::KeepAwake($false)
    foreach ($c in @($numStart, $numEnd, $btnPick, $btnStart, $chkRepeat)) { $c.Enabled = $true }
    $btnStop.Enabled = $false
    Write-Log '정지'
    Update-Status
}

# ---------- UI ----------
$font = New-Object System.Drawing.Font('Malgun Gothic', 9.5)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'MyClicker - 한 시간에 한 번 랜덤 클릭'
$form.Font = $font
$form.ClientSize = New-Object System.Drawing.Size(470, 440)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

function New-Label($text, $x, $y, $w = 120) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 22)
    $l.TextAlign = 'MiddleLeft'
    $form.Controls.Add($l); return $l
}
function New-Num($min, $max, $val, $x, $y) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = $min; $n.Maximum = $max; $n.Value = $val
    $n.Location = New-Object System.Drawing.Point($x, $y); $n.Size = New-Object System.Drawing.Size(55, 24)
    $form.Controls.Add($n); return $n
}
function New-Button($text, $x, $y, $w = 100) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 30)
    $form.Controls.Add($b); return $b
}
function New-Check($text, $x, $y, $checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.Checked = $checked; $c.AutoSize = $true
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $form.Controls.Add($c); return $c
}

[void](New-Label '동작 시간' 15 15 80)
$numStart = New-Num 0 23 ([Math]::Min(23, (Get-Date).Hour)) 100 15
[void](New-Label '시  ~' 160 15 40)
$numEnd   = New-Num 0 24 ([Math]::Min(24, (Get-Date).Hour + 2)) 205 15
[void](New-Label '시 (종료 시각 미포함)' 265 15 190)

[void](New-Label '클릭 위치' 15 50 80)
$lblPos  = New-Label '(미지정)' 100 50 140
$btnPick = New-Button '위치 지정' 245 46 100
$btnTest = New-Button '테스트 클릭' 350 46 105

[void](New-Label '위치 흔들림 ±' 15 85 100)
$numJitter = New-Num 0 30 3 115 85
[void](New-Label '픽셀' 175 85 50)

$chkRepeat = New-Check '매일 반복 (끄면 이번 범위만 하고 정지)' 15 115 $true
$chkReturn = New-Check '클릭 후 마우스를 원래 위치로 되돌리기' 15 140 $true

$btnStart = New-Button '시작' 15 172 215
$btnStop  = New-Button '정지' 240 172 215
$btnStop.Enabled = $false

$lblNext = New-Label '정지됨' 15 210 440
$lblNext.Font = New-Object System.Drawing.Font('Malgun Gothic', 10, [System.Drawing.FontStyle]::Bold)

$lstLog = New-Object System.Windows.Forms.ListBox
$lstLog.Location = New-Object System.Drawing.Point(15, 240)
$lstLog.Size = New-Object System.Drawing.Size(440, 185)
$lstLog.HorizontalScrollbar = $true
$form.Controls.Add($lstLog)

# 위치 지정: 3초 카운트다운 동안 마우스를 버튼 위에 올려두면 그 좌표를 저장
$pickTimer = New-Object System.Windows.Forms.Timer
$pickTimer.Interval = 1000
$pickTimer.Add_Tick({
    $script:countdown--
    if ($script:countdown -gt 0) {
        $btnPick.Text = "$($script:countdown)초 후 저장"
    } else {
        $pickTimer.Stop()
        $script:target = [HumanMouse]::GetPos()
        $lblPos.Text = '({0}, {1})' -f $script:target[0], $script:target[1]
        $btnPick.Text = '위치 지정'
        $btnPick.Enabled = -not $script:running
        Write-Log ("클릭 위치 저장: " + $lblPos.Text)
    }
})
$btnPick.Add_Click({
    $script:countdown = 3
    $btnPick.Enabled = $false
    $btnPick.Text = '3초 후 저장'
    Write-Log '3초 안에 마우스를 누를 버튼 위에 올려 두세요...'
    $pickTimer.Start()
})

$btnTest.Add_Click({
    if (-not $script:target) { [System.Windows.Forms.MessageBox]::Show('먼저 위치를 지정해 주세요.', 'MyClicker') | Out-Null; return }
    $where = Invoke-HumanClick
    Write-Log "테스트 클릭 $where"
})

$btnStart.Add_Click({ Start-Clicker })
$btnStop.Add_Click({ Stop-Clicker })

# 1초마다 확인. 실제 시계 기준이라 오래 켜 둬도 시간이 밀리지 않음.
$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = 1000
$tick.Add_Tick({
    if (-not $script:running -or -not $script:nextClick) { return }
    $now = Get-Date
    Update-Status
    if ($now -lt $script:nextClick) { return }
    $tick.Stop()
    try {
        if ($now -ge $script:nextSlot.AddHours(1)) {
            # PC가 잠들어 있었거나 해서 그 시간을 통째로 놓친 경우
            Write-Log ("놓침: {0:HH}시대 (예정 {1:HH:mm:ss})" -f $script:nextSlot, $script:nextClick)
            Set-NextClick $now $now.AddSeconds(10)
        } else {
            $where = Invoke-HumanClick
            $script:lastClick = Get-Date
            Write-Log ("클릭 {0}  ({1:HH}시대)" -f $where, $script:nextSlot)
            Set-NextClick $script:nextSlot.AddHours(1) $script:lastClick.AddSeconds($MIN_GAP_SEC)
        }
    } catch {
        Write-Log ("오류: " + $_.Exception.Message)
        Set-NextClick (Get-Date).AddHours(0) (Get-Date).AddSeconds(30)
    }
    if ($script:running) { $tick.Start() }
})

$form.Add_FormClosing({
    $tick.Stop(); $pickTimer.Stop()
    [HumanMouse]::KeepAwake($false)
})

Write-Log '1) 동작 시간 선택  2) 위치 지정  3) 시작'
[void]$form.ShowDialog()

} catch {
    [System.Windows.Forms.MessageBox]::Show("오류가 발생했습니다:`n`n$($_.Exception.Message)", 'MyClicker') | Out-Null
}
