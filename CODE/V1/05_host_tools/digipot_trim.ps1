# digipot_trim.ps1 — 即時顯示 raw 通道,用來調可變電阻 / 檢查 digipot 接線
# ===========================================================================
# 不需要新 bitstream:直接讀目前板子在送的 TTCGS 幀流,把 raw 維度解出來,
# 換算成電阻,並告訴你可變電阻該往哪轉。
#
# 用法:
#   .\digipot_trim.ps1                     # 自動找埠,目標 1872 counts
#   .\digipot_trim.ps1 -Port COM7
#   .\digipot_trim.ps1 -Target 1612        # 整合建置後、digipot 停在 1746 時用
#   .\digipot_trim.ps1 -RawDim 2           # 若 raw 不在 d12
#
# 目標值怎麼來的(兩個階段不一樣,別用錯):
#   階段1 現在   digipot 未被驅動,上電停在 EEMEM 預設 midscale = 8x128 = 碼 1024
#                R_pot = 1024 x 390.625 + 600 = 400.6k
#                想要偏置 = 1.25M  ->  總阻 1.651M  ->  raw = 1872 counts
#   階段2 整合後 man_en 停在碼 1746 -> R_pot = 682.7k -> 總阻 1.933M -> raw = 1612
#   兩階段調出來的是同一個偏置。階段1 先粗調並確認接線,階段2 才定案。
#
# 幀格式(見 log_frames.py):0xAA 0xA5 <len> <51 byte payload>
#   payload[0..1]   0xAA 0x55
#   payload[6+2d]   dim d,大端有號 16-bit
#   payload[48]     status  bit3 uncal / bit6 ads_init_done / bit7 ads_err
#   payload[49..50] CRC16-CCITT over payload[0..48]
# ===========================================================================
param(
    [string]$Port   = "",
    [int]$Baud      = 921600,
    [double]$Target = 1872,
    [int]$RawDim    = 12,
    [double]$Rref   = 100000,
    [int]$ExpectBid = 0x093A     # 不符會在 BID 後面加 "!"
)

function Get-Crc16([byte[]]$d, [int]$off, [int]$len) {
    $crc = 0xFFFF
    for ($i = 0; $i -lt $len; $i++) {
        $crc = $crc -bxor ([int]$d[$off + $i] -shl 8)
        for ($b = 0; $b -lt 8; $b++) {
            if ($crc -band 0x8000) { $crc = ((($crc -shl 1) -bxor 0x1021)) -band 0xFFFF }
            else                   { $crc = (($crc -shl 1)) -band 0xFFFF }
        }
    }
    return $crc
}

if (-not $Port) {
    # @() 是必要的:只有一個埠時 Sort-Object 回傳純量字串,[-1] 會變成
    # 對字串取最後一個字元("COM7" -> "7"),開埠就會失敗。
    $names = @([System.IO.Ports.SerialPort]::GetPortNames())
    if ($names.Count -eq 0) { Write-Host "找不到 COM 埠 — FPGA 插了嗎?"; exit 1 }
    $sorted = @($names | Sort-Object { [int]($_ -replace '\D', '') })
    $Port = $sorted[$sorted.Count - 1]
    Write-Host "自動選埠: $Port  (可用: $($names -join ', '))"
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 1000
$sp.ReadBufferSize = 1048576
try { $sp.Open() } catch { Write-Host "開埠失敗: $($_.Exception.Message)"; exit 1 }

Write-Host ""
Write-Host "目標 raw = $Target counts.  Ctrl+C 停止."
Write-Host "轉可變電阻時看『該轉哪邊』那欄;counts 偏低=電阻太大,要調小." -ForegroundColor DarkGray
Write-Host ""

$buf = New-Object byte[] 65536
try {
  while ($true) {
    Start-Sleep -Milliseconds 400
    $n = 0
    try { $n = $sp.Read($buf, 0, $buf.Length) } catch [TimeoutException] {
        Write-Host "[1s 無資料 — bitstream 有在送幀嗎?]" -ForegroundColor Yellow; continue
    }
    if ($n -lt 54) { continue }

    $vals = New-Object System.Collections.Generic.List[double]
    $bad = 0; $stat = 0; $bid = -1
    $i = 0
    while ($i -lt ($n - 3)) {
        if ($buf[$i] -eq 0xAA -and $buf[$i+1] -eq 0xA5) {
            $len = [int]$buf[$i+2]
            if ($len -ge 51 -and ($i + 3 + $len) -le $n) {
                $p = $i + 3
                $calc = Get-Crc16 $buf $p 49
                $got  = ([int]$buf[$p+49] -shl 8) -bor [int]$buf[$p+50]
                if ($calc -eq $got) {
                    $o = $p + 6 + 2 * $RawDim
                    $v = ([int]$buf[$o] -shl 8) -bor [int]$buf[$o+1]
                    if ($v -ge 32768) { $v -= 65536 }
                    $vals.Add([double]$v)
                    $stat = [int]$buf[$p+48]
                    # BID_DIM = 4 (dsp_chain.v):跑的是哪一版 bitstream。
                    # SRAM 斷電回退 / RESET 從 flash 重載 / Verify Failed 假警報
                    # ——三種跑到舊 bitstream 的方式都不報錯,只有這個數字會說實話。
                    $ob  = $p + 6 + 2 * 4
                    $bid = ([int]$buf[$ob] -shl 8) -bor [int]$buf[$ob+1]
                } else { $bad++ }
                $i = $p + $len; continue
            }
        }
        $i++
    }

    if ($vals.Count -lt 3) {
        Write-Host ("[只解出 {0} 幀, CRC 壞 {1}]  — 埠被別的程式佔住?或跑的不是含幀鏡射的 bitstream" -f $vals.Count, $bad) -ForegroundColor Yellow
        continue
    }

    $mean = ($vals | Measure-Object -Average).Average
    $sd   = [math]::Sqrt((($vals | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum) / $vals.Count)

    if ($mean -gt 0 -and $mean -lt 32767) {
        $R = $Rref * (32767.0 / $mean - 1.0)
        $Rtxt = "{0,8:F1} k" -f ($R / 1000.0)
    } else { $Rtxt = "   ----  " }

    $d = $mean - $Target
    if ([math]::Abs($d) -le 3)      { $hint = "★ 到位"; $col = "Green" }
    elseif ($d -lt 0)               { $hint = "→ 調小電阻 (counts 太低 $([math]::Round($d,0)))"; $col = "Cyan" }
    else                            { $hint = "← 調大電阻 (counts 太高 +$([math]::Round($d,0)))"; $col = "Cyan" }

    $flags = @()
    if ($stat -band 0x80) { $flags += "ADS_ERR" }
    if (-not ($stat -band 0x40)) { $flags += "ADS_未init" }
    if ($stat -band 0x08) { $flags += "校正中" }
    $ftxt = if ($flags.Count) { " [" + ($flags -join " ") + "]" } else { "" }

    $bidtxt = if ($bid -ge 0) { "BID 0x{0:X4}" -f $bid } else { "BID ----" }
    if ($bid -ge 0 -and $bid -ne $ExpectBid) { $bidtxt += "!" }   # 不是預期的那版

    Write-Host ("{0}  raw {1,8:F1}  sd {2,5:F2}  n={3,4}  R={4}Ω   {5}{6}" -f `
        $bidtxt, $mean, $sd, $vals.Count, $Rtxt, $hint, $ftxt) -ForegroundColor $col
  }
}
finally { if ($sp.IsOpen) { $sp.Close() }; Write-Host "`n埠已關閉." }
