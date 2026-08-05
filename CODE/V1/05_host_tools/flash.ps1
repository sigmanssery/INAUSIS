# flash.ps1 — 燒錄 Tang Nano 9K，自動挑對 JTAG 通道
#
#   .\flash.ps1                      # 燒預設的 dual_rpmin46_st.fs
#   .\flash.ps1 -Fs ldc_fast.fs      # 燒指定的 bitstream
#   .\flash.ps1 -Check               # 只讀 device code，不燒
#
# 為什麼需要這個：FT2232 有兩個 USB 介面（JTAG 和 UART），programmer_cli
# 不指定 --location 時會解析成 None 然後永久卡住（Ctrl+C 也殺不掉）。
# location 號碼會隨 USB 埠改變，所以每次掃描後逐一測試，挑出能回應的那個。

param(
    [string]$Fs = "dual_rpmin46_st.fs",
    [switch]$Check,
    # -Flash 寫進內建 flash（--run 6，含驗證）而不是 SRAM（--run 2）。
    # SRAM 版斷電就沒了，FPGA 會自動重載 flash 裡的舊 bitstream —— 長時間錄製
    # 途中一個電源瞬斷，韌體就會悄悄換版而你不會發現（2026-08-01 踩過）。
    # 慢很多，但過夜或跑一小時以上的量測一律用這個。
    [switch]$Flash
)

$ErrorActionPreference = "Stop"
$PROG   = "C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe"
$DEVICE = "GW1NR-9C"

if (-not (Test-Path $PROG)) { Write-Host "找不到 programmer_cli：$PROG" -Fore Red; exit 1 }

# programmer_cli 內嵌 Python，會被繼承的環境變數搞壞
$env:PYTHONIOENCODING = $null; $env:PYTHONHOME = $null; $env:PYTHONPATH = $null

function Kill-Stale {
    $p = Get-Process -Name programmer_cli -ErrorAction SilentlyContinue
    if ($p) { $p | Stop-Process -Force; Start-Sleep -Milliseconds 300 }
}

# 跑 programmer_cli，逾時就強制殺掉（卡住時它不理會中斷訊號）
function Run-Prog([string[]]$Arguments, [int]$TimeoutSec) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $PROG -ArgumentList $Arguments -NoNewWindow -PassThru `
                       -RedirectStandardOutput $o -RedirectStandardError $e
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        Start-Sleep -Milliseconds 300
        Remove-Item $o, $e -ErrorAction SilentlyContinue
        return @{ TimedOut = $true; Code = -1; Out = "" }
    }
    # 逾時版的 WaitForExit 回傳後 ExitCode 可能還是 null，要再等一次無參數版
    $p.WaitForExit()
    $code = if ($null -ne $p.ExitCode) { [int]$p.ExitCode } else { 0 }
    $txt = ((Get-Content $o -Raw -ErrorAction SilentlyContinue) +
            (Get-Content $e -Raw -ErrorAction SilentlyContinue))
    Remove-Item $o, $e -ErrorAction SilentlyContinue
    return @{ TimedOut = $false; Code = $code; Out = $txt }
}

Kill-Stale

# --- 掃描下載線，取出所有 location ---
$scan = Run-Prog @("--scan-cables") 20
if ($scan.TimedOut -or $scan.Code -ne 0) { Write-Host "掃描下載線失敗 — 板子插了嗎？" -Fore Red; exit 1 }

$locs = [regex]::Matches($scan.Out, 'USB location:\s*(\d+)') |
        ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique
if (-not $locs) { Write-Host "沒有偵測到下載線。" -Fore Red; exit 1 }
Write-Host "偵測到 location: $($locs -join ', ')"

# --- 逐一測試，能回應 Read Device Codes 的才是 JTAG 通道 ---
$jtag = $null
foreach ($l in $locs) {
    Write-Host -NoNewline "  測試 location $l ... "
    $r = Run-Prog @("--device", $DEVICE, "--run", "0", "--location", "$l") 12
    if (-not $r.TimedOut -and $r.Code -eq 0 -and $r.Out -match 'ID Code') {
        $id = ([regex]::Match($r.Out, 'ID Code is:\s*(\S+)')).Groups[1].Value
        Write-Host "JTAG ✓  ID=$id" -Fore Green
        $jtag = $l; break
    }
    Write-Host $(if ($r.TimedOut) { "無回應（UART 通道）" } else { "失敗" }) -Fore DarkGray
    Kill-Stale
}
if ($null -eq $jtag) { Write-Host "沒有任何 location 回應 JTAG。按板上重置鈕後重試。" -Fore Red; exit 1 }

if ($Check) { Write-Host "`nJTAG 通道 = location $jtag" -Fore Green; exit 0 }

# --- 燒錄 ---
$path = if (Test-Path $Fs) { (Resolve-Path $Fs).Path } else { Join-Path $PSScriptRoot $Fs }
if (-not (Test-Path $path)) { Write-Host "找不到 bitstream：$path" -Fore Red; exit 1 }

$op   = if ($Flash) { "6" } else { "2" }
$what = if ($Flash) { "內建 flash（斷電保留）" } else { "SRAM（斷電即失）" }
Write-Host "`n燒錄 $(Split-Path $path -Leaf) -> $what  (location $jtag) ..."
$r = Run-Prog @("--device", $DEVICE, "--run", $op, "--location", "$jtag", "--fsFile", $path) 300
if ($r.TimedOut) { Kill-Stale; Write-Host "燒錄逾時，已強制終止。" -Fore Red; exit 1 }

($r.Out -split "`n" | Where-Object { $_ -notmatch 'Programing|Programming\.\.\.' -and $_.Trim() }) |
    ForEach-Object { Write-Host "  $($_.TrimEnd())" }

if ($r.Code -ne 0 -or $r.Out -notmatch 'Finished') {
    Write-Host "`n燒錄失敗（exit $($r.Code)）" -Fore Red; exit 1
}
# programmer_cli 會在 Verify 失敗後仍然印 "Finished" 並回傳 0，所以要另外攔。
if ($r.Out -match 'Verify Failed') {
    Write-Host "`n*** 燒錄完成但 VERIFY 失敗 —— 寫進去的內容跟檔案不符。" -Fore Yellow
    Write-Host "    先確認實際行為（讀 UART 看是不是預期的版本），" -Fore Yellow
    Write-Host "    要驗證 flash 真的保留，拔插一次 USB 再看一次。" -Fore Yellow
} else {
    Write-Host "`n燒錄成功 ✓" -Fore Green
}

# JTAG 燒錄會讓 FT2232 重新列舉，UART 那一側的 COM 埠要幾秒才回來。
# 不等的話，緊接著跑 run_log.ps1 會得到「找不到 COM 口」。
Write-Host -NoNewline "等待 COM 埠回來 "
for ($i = 0; $i -lt 20; $i++) {
    $ports = @([System.IO.Ports.SerialPort]::GetPortNames())
    if ($ports.Count -gt 0) { Write-Host " -> $($ports -join ', ') ✓" -Fore Green; exit 0 }
    Write-Host -NoNewline "."
    Start-Sleep -Milliseconds 500
}
Write-Host " 逾時 — COM 埠沒有回來，拔插一次 USB。" -Fore Yellow
