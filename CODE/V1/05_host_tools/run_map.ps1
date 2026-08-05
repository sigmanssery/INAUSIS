# run_map.ps1 — launch the INAUSIS tactile map (wrapper around tactile_map.py).
# The COM port can only be held by ONE program, so read_uart.ps1 must be closed
# first; -Raw makes the map echo the live values into this console instead.
#
#   .\run_map.ps1                 # auto-detect the port, echo values on
#   .\run_map.ps1 -Port COM7
#   .\run_map.ps1 -Raw:$false     # quiet console, window only
#   .\run_map.ps1 -Extra "--thresh-k 1.0 --smooth 0.15"
param(
    [string]$Port = "",
    [switch]$Raw = $true,
    [string]$Extra = ""
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

$args = @("tactile_map.py", "--port", $Port)
if ($Raw) { $args += "--raw" }
if ($Extra) { $args += $Extra.Split(" ") }

Write-Host "校正時請勿碰觸感測墊(約 2 秒)。關閉視窗即結束。`n"
& python @args
