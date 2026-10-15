# AXI_AHB_Bridge_Homework

# SoC Bus Interconnect Wrapper & FSM Design (AHB & AXI4)



本專案實作了片上系統（SoC）常用匯流排協定 **AMBA AHB** 與 **AMBA AXI4** 的匯流排轉接器（Bus Wrapper）與有限狀態機（FSM），並設計了支援多主控端（Multi-Master）與多被控端（Multi-Slave）的匯流排架構。

---

## 📌 系統拓撲架構 (System Topology)

### 1. AHB Protocol System Architecture (3 Masters / 3 Slaves)



* **Master 端**：`CPU Core` (Master #1)、`SIP-DMA` (Master #2)、`DSP Core` (Master #3)。


* **Slave 端**：`Memory Controller` (Slave #1)、`SIP-UART` (Slave #2)、`GPIO/Timer` (Slave #3)。


* **Interconnect 關鍵模組**：


* **Arbiter（仲裁器）**：處理多個 Master 競逐同一 Slave 的存取權限；存取不同 Slave 時允許並行傳輸。


* **Decoder（解碼器）**：解析 `HADDR` 並產生相對應 Slave 的片選訊號 (`HSELx`)。


* **Read Data MUX**：導通被選中 Slave 的 `HRDATA`、`HRESP` 與 `HREADYOUT`，其中 `HREADYOUT` 作為全域 `HREADY` 廣播至所有模組。





### 2. AXI4 Protocol System Architecture (4 Masters / 4 Slaves)



* **Master 端**：`CPU Core` (Master #1)、`SIP-DMA` (Master #2)、`DSP Core` (Master #3)、`GPU Engine` (Master #4)。


* **Slave 端**：`Memory Controller` (Slave #1)、`SIP-UART` (Slave #2)、`GPIO/Timer` (Slave #3)、`SPI Flash` (Slave #4)。


* **Interconnect 關鍵模組**：


* **Crossbar Switch Matrix**：提供讀寫獨立的 5 通道（`AW`, `W`, `B`, `AR`, `R`）非阻塞並行架構。


* **ID Tag Routing**：採用 ID 前綴（Prefix）進行路由標記與解標記，支援 **Out-of-Order Completion（亂序完成）** 與 **Interleaving（交錯傳輸）**。





---

## 🔄 狀態機設計 (FSM Architecture)

### 1. AHB Master / Slave Wrapper FSM



* **Read / Write Transaction Flow**：


* **Master FSM**：`M_IDLE` ➔ `M_ADDR` (發送 `NONSEQ`) ➔ `M_BURST` (發送 `SEQ` 突發傳輸) ➔ `M_LAST` ➔ `M_DONE` (發送中斷 `INTR`)。若遇到異常則切換至 `M_ERR` 處理。


* **Slave FSM**：`R_IDLE`/`W_IDLE` ➔ `R_WAIT` (鎖存位址與控制訊號) ➔ `R_DATA`/`W_DATA` (進行資料存取，以 `HREADYOUT` 控制 Wait State)。





### 2. AXI4 Master / Slave Wrapper FSM



* **Read Transaction Flow (AR & R Channels)**：


* **Master Read FSM**：`M_IDLE` ➔ `M_AR` (驅動 `ARVALID` & 位址) ➔ `M_R` (接收 `RVALID` 與 `RLAST` 資料) ➔ `M_DONE`。


* **Slave Read FSM**：`R_IDLE` ➔ `R_WAIT` ➔ `R_ACCESS` ➔ `R_DATA` (發送 `RLAST` 與 `RID` 標籤)。




* **Write Transaction Flow (AW, W, & B Channels)**：


* **Master Write FSM**：`M_IDLE` ➔ `M_AW` (寫入位址握手) ➔ `M_W` (寫入資料與 `WLAST`) ➔ `M_B` (等待 `BVALID` 回應) ➔ `M_DONE`。


* **Slave Write FSM**：`W_IDLE` ➔ `W_DATA` ➔ `W_ACCESS` ➔ `W_RESP` (返回 `BRESP` 寫入完成回應)。
<img width="4258" height="2402" alt="AXI_AHB_MASTER_SLAVE" src="https://github.com/user-attachments/assets/cc2f4e42-21b5-4ebb-8890-27783f2ef992" />




# Message Sequence Chart (MSC): AHB vs. AXI DMA Transfer Flow



在系統（SoC）中，**CPU 設定 SIP DMA 控制暫存器**，並由 **DMA 自動將資料搬移至 Memory** 的完整訊息時序圖（Message Sequence Chart）。圖中詳細對比了 AMBA AHB 與 AMBA AXI4 兩種協定在傳輸機制上的核心差異。

---

## 👥 系統角色定義 (Lifelines)

* **`CPU (Master)`**：發起配置指令的主控端。


* **`SIP DMA (Slave 端：暫存器)`**：被控端，接收 CPU 寫入的配置參數（如 Pkt 起始/終點位址與長度）。


* **`SIP DMA (Master 端：搬移)`**：主控端，收到內部啟動訊號後，主動發起對 Memory 的資料搬移。


* **`Memory Ctrl (Slave)`**：被控端，接收 DMA 寫入的位址與資料。



---

## 🔄 四大階段傳輸流程拆解

### ❶ CPU 配置 SIP 暫存器 (CPU Configures SIP Registers)



* **AHB 協定**：
* **Phase 1 (位址階段)**：CPU 送出 `HTRANS = NONSEQ`, `HWRITE = 1` 與位址 `HADDR`。


* **Phase 2 (資料階段)**：隔一拍（Pipeline 重疊）送出寫入數據 `HWDATA`。


* **Ack**：SIP DMA 返回 `HREADY = 1, HRESP = OKAY` 完成寫入。




* **AXI 協定**：
* **AW 通道**：`AWADDR, AWVALID` 與 `AWREADY` 完成寫入位址握手。


* **W 通道**：`WDATA, WVALID, WLAST` 與 `WREADY` 完成寫入數據握手。


* **B 通道**：`BVALID, BRESP = OKAY` 與 `BREADY` 完成寫入回應握手。





---

### ❷ SIP DMA 內部啟動 (DMA Internal Trigger)



* **AHB (Step 4) / AXI (Step 7)**：SIP DMA 內部的邏輯電路解碼完成後，發送內部觸發訊號（`Start, Length`），啟動 DMA Master 模組進行自動搬移。



---

### ❸ DMA 搬移資料至 Memory (DMA Memory Transfer Phase)



* **AHB 協定**：
* DMA 發起 `HTRANS = NONSEQ` 位址階段與 `HWDATA` 資料階段。


* 若 Memory 忙碌，可拉低 `HREADY = 0` 插入 Wait State。


* 當 `HREADY = 1` 時完成該拍傳輸；後續突發傳輸（Burst）改用 `HTRANS = SEQ` 與 `HADDR` 自動遞增。




* **AXI 協定**：
* **AW 通道**：傳送位址與突發設定（`AWADDR, AWLEN, AWSIZE, AWBURST`）並進行握手。


* **W 通道**：連續傳送突發資料（`WDATA`），最後一筆加上 `WLAST = 1` 標記。


* **B 通道**：整組 Burst 傳輸完全結束後，由 Memory 返回一次性寫入回應（`BVALID, BRESP`）。





---

### ❹ 中斷通報 (Interrupt Notification)



* **AHB (Step 9) / AXI (Step 14)**：整組 Packet 搬移完成後，SIP DMA 透過 Dedicated Sideband 訊號發送中斷請求（`IRQ`）通知 CPU。



---
<img width="2062" height="1567" alt="ahbaxi_Message Sequence Chart" src="https://github.com/user-attachments/assets/2b153b52-e761-43dc-8427-a79ac08612f2" />



---

## 🛠️ 開發與模擬工具

* **Diagraming**：[diagrams.net (Draw.io)](https://app.diagrams.net/)


