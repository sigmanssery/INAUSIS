# 冷開機失效:板子無法獨立啟動(2026-08-28,已修)

## 徵象

把 bitstream 燒進 FPGA 內建 flash、拔掉 USB 再插上之後:

    幀率 690/s、CRC 全過、時戳連續   <- 設計有載入,鏈路正常
    dead map = 0x3FFFF              <- 18 維全部標死
    d2 恆為 0、d12 完全不更新        <- 轉換器沒有在轉

**同一顆 bitstream 用 JTAG 燒到 SRAM 就完全正常**(dead 0x3FFF8、d2 1776~1788、
d12 630 Hz)。差別只有一個:JTAG 燒錄時 ADS 已經通電好幾分鐘。

## 根因

冷插上 USB 時,FPGA 從內建 flash 組態完成得比 ADS 的電源建立快。驅動等 5 ms
(`POR_CYC = 135000`)就開始寫暫存器,那些寫入落在一個還沒在聽的裝置上,
被吃掉。`init_done` 照樣拉起來,晶片停在預設狀態,輸出恆零。

**這在幾個月的 bring-up 裡從沒出現過,因為每次都是 JTAG 燒的。**
只有真正斷電重開才會踩到 —— 也就是說,這塊板在此之前**從來沒有真正獨立啟動過**。

## 修法(兩層,缺一不可)

**1. `ads114s08_spi.v`:上電等待 5 ms → 50 ms**(`POR_CYC` 135000 → 1350000)。

**2. 同檔:連續 64 個「剛好是 0」的讀值就整個重做初始化。** 活著的轉換器不會
連續回傳精確的零 —— 自身雜訊會讓 LSB 抖動。所以即使 50 ms 仍不夠,
64 個樣本(584 SPS 下約 110 ms)之內會自動重來。與 LDC 驅動的 chip-ID 自癒同形。

**3. `ttcgs_board.v`:`sample_en` 改為等到「ADS 送出非零樣本」才放行**,
不再只看 `init_done`。

第 3 點是前兩點的必要補充:`zscore_flag_multi` **只在開機後的前 CAL_N 個樣本
校正一次**。若校正跑在全零資料上,dead map 會是 0x3FFFF,而且**即使驅動之後
自癒、真實資料開始流動,那張圖仍然是錯的**,下游照它會把所有東西丟掉。
把 `sample_en` 綁在「見到活資料」上,校正才會在有效訊號上進行。

## Gowin programmer 的 verify 失敗是假警報

`embFlash Erase,Program,Verify` 每次都報 `Error: Verify Failed at 0`,
但斷電重開後**設計確實正確載入**(幀率、封包格式、鏈路都對,只有 ADS 沒醒)。
所以那個 verify 訊息不可信,**要判斷 flash 是否寫入成功,只能靠拔插後看實際行為**。

## 已驗證通過(2026-08-28 21:35)

`board_coldstart.fs` 燒入 flash,拔 USB 重插後實測:

    dead map     262136 (0x3FFF8)   <- 修好前的冷開機是 0x3FFFF(18 維全死)
    d12 更新率   628 Hz
    d2 範圍      1776 ~ 1786        <- 轉換器有在轉,不是恆零
    幀率 683/s、badCRC 0、dropped 0 stale

`dropped 0 stale` 是額外的佐證:先前每次錄製都要丟 74~76 幀主機端緩衝的殘留,
這次為零,表示板子是剛開始送資料,確實是冷開機而非接續既有串流。

**三項判準全過,修法成立。**

## 副作用:拔插後 FTDI 介面 B 可能掛掉

這次拔插後 Windows 完全沒有 COM 埠。查 `Get-PnpDevice` 發現:

    USB Serial Converter A (JTAG)  CM_PROB_NONE          <- 正常
    USB Serial Converter B (UART)  CM_PROB_FAILED_START  <- 掛掉

所以 `flash.ps1 -Check` 會顯示「偵測到 location 593 但無回應」——
它看到的是還活著的 JTAG 那半邊。

**解法:拔掉,插到「另一個」USB 埠**(換埠會建立全新的裝置實例)。實測有效。

**不要跑 Zadig。** 它的 libwdi 驅動跟 FTDI 打架,正是會造成 `CM_PROB_FAILED_START`
的東西,而且要手動清 `oem*.inf` 才救得回來。這個狀態換埠就能好,跑 Zadig 會變成真的難救。
