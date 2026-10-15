# AXI_AHB_Bridge_Homework
這是一份非常適合直接放在 **GitHub README.md** 的專案架構與狀態機說明模板。

你可以直接複製下方 Markdown 內容貼到你的 GitHub README 中，它包含了**專案簡介**、**核心模組架構**與**狀態機 (FSM) 運行邏輯**：

---

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






---

## 🛠️ 開發與模擬工具

* **Diagraming**：[diagrams.net (Draw.io)](https://app.diagrams.net/)

* **RTL Language**：Verilog / SystemVerilog
* **Simulation**：Icarus Verilog + GTKWave / Vivado XSIM
