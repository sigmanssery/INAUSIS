# run_log.ps1 — record the top_dual UART stream to CSV (wrapper for log_dual.py).
# Names the file to the project convention  YYYY-MM-DD_<主題>_raw.csv  and drops it
# in the data folder, so captures stay comparable across sessions.
#
#   .\run_log.ps1 -Name MRE_press                # 30 s, auto-detect port
#   .\run_log.ps1 -Name ADS_corner-survey -Secs 40
#   .\run_log.ps1 -Name LDC_idle -Secs 20 -Port COM7
#   .\run_log.ps1 -Name foo -Secs 0              # 0 = run until Ctrl+C
#
# While recording: type a label + ENTER to mark an event (e.g. "press", "release").
# The COM port can only be held by ONE program — close read_uart.ps1 / tactile_map
# first.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$Secs = 30,
    [string]$Port = "",
    [string]$DataDir = "C:\Users\Admin\Desktop\INAUSIS\data"
)

$ports = @([System.IO.Ports.SerialPort]::GetPortNames())
Write-Host "可用 COM 口: $($ports -join ', ')"
if (-not $Port) {
    if ($ports.Count -eq 0) { Write-Host "找不到 COM 口 — FPGA 插了嗎?"; exit 1 }
    # the Tang Nano exposes two interfaces; the data UART is the higher-numbered one.
    # @() is load-bearing: with a single port the pipeline yields a *string*, and
    # [-1] would index its last character ("COM7" -> "7").
    $Port = @($ports | Sort-Object { [int]($_ -replace '\D', '') })[-1]
    Write-Host "未指定 -Port,自動選用 $Port(錯的話用 -Port COMx 指定)"
}

$stamp = Get-Date -Format "yyyy-MM-dd"
$out = Join-Path $DataDir "${stamp}_${Name}_raw.csv"
if (Test-Path $out) {
    $n = 2
    while (Test-Path (Join-Path $DataDir "${stamp}_${Name}-$n`_raw.csv")) { $n++ }
    $out = Join-Path $DataDir "${stamp}_${Name}-$n`_raw.csv"
    Write-Host "同名檔已存在,改存為 $(Split-Path $out -Leaf)"
}

$argv = @("log_dual.py", "--port", $Port, "--out", $out)
if ($Secs -gt 0) { $argv += @("--secs", $Secs) }

# 超過 10 分鐘的錄製一律關掉 stdout。Windows 主控台的 QuickEdit 會在你點一下視窗時
# 阻塞下一次 print，錄製就停在那裡（2026-08-04 兩次 10 小時錄製死在 70/87 分）。
$quiet = $Secs -gt 600
if ($quiet) { $argv += "--quiet" }

Write-Host ""
Write-Host "-> $out"
if ($quiet) {
    Write-Host "長時間錄製:已關閉畫面輸出(避免主控台 QuickEdit 凍住行程)。"
    Write-Host "要看進度,另開一個視窗執行:"
    Write-Host "  Get-Content '$out.status' -Wait" -Fore Cyan
    Write-Host "錄製期間請勿在這個視窗點擊。Ctrl+C 停止。`n"
} else {
    Write-Host "錄製中:打字 + ENTER 可標記事件(例如 press / release),Ctrl+C 停止。`n"
}
& python @argv

if (Test-Path $out) {
    $rows = (Get-Content $out | Measure-Object -Line).Lines - 1
    Write-Host "`n完成:$rows 列  ->  $out"
}
