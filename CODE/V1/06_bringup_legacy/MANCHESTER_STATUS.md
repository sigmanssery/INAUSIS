# 曼徹斯特傳輸層 - 進度與下次起點

## 已完成且驗證 ✓
- **manchester_enc.v**: byte 級編碼器, IEEE 802.3 (0=高低, 1=低高), HALF_CLKS=8. 正確.
- **manchester_rx.v**: 解碼器, preamble 鎖相成功 (0x55 的 edge 間隔=BIT_CLKS=16, 數 6+ 個規律 edge 鎖定), SFD(0xD5) 滑動偵測對齊成功.
- **manchester_tx.v**: frame wrapper, buffered payload (無握手 race), 發送 PREAMBLE(4x0x55)+SFD+payload. TX 送出正確.

## 今晚解決的關鍵問題
1. MSB 丟失: byte 進入跳變被誤當 bit7 mid-bit → 加 first_mid 區分
2. preamble 間隔算錯: 0x55 的 mid-bit 間隔是 BIT_CLKS(16) 不是 HALF_CLKS(8), 因為相鄰 0,1 bit 的 boundary 無跳變
3. SFD byte 對齊: 用滑動 8-bit 視窗比對 SFD, match 後對齊 payload byte grid
4. TX 握手 race: 改用 buffered payload 消除

## 剩下的問題 (下次起點) ⚠️
**連續多 byte 的 byte 間銜接時序**:
- 症狀: 單 payload byte 沒收到; 4-byte 收到 payload[1],[3] (每隔一個漏)
- 根因: enc 在 byte 之間回 IDLE, data_line 保持上個電平. byte 銜接處若「上個 byte 尾電平 == 下個 byte 第一 bit 前半電平」則無跳變, 反之有跳變 → 干擾 RX 的 mid-bit 計時, 漏掉或誤判 byte 邊界的第一個 bit.
- **正解方向**: enc 改「連續流模式」, byte 之間不回 IDLE, 讓所有 mid-bit edge 嚴格等 BIT_CLKS 間隔; RX 用純 timer 在鎖相後連續取樣, 不依賴 byte 間 entry edge. 
- 或: RX 在 SFD 後改用「純計時取樣」(每 BIT_CLKS 在 bit 中點取電平判斷前後半), 完全不靠 edge 偵測 byte 邊界.

## 測試檔
- tb_manch_frame.v: 4-byte loopback (A5 C3 0F 5A), 目前收到 C3,5A
- 下次: 先修連續 byte 銜接, 通過 4-byte loopback, 再餵完整 48-byte frame
