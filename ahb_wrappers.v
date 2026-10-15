// ============================================================================
//  AHB Wrappers  (對應圖中 "AHB Read/Write Transfer Flow")
//    - ahb_master_wrapper : M_IDLE -> M_ADDR -> M_BURST -> M_LAST -> M_DONE (+M_ERR)
//    - ahb_slave_wrapper  : Read  FSM  R_IDLE -> R_WAIT -> R_DATA
//                           Write FSM  W_IDLE -> W_DATA
//    - ip_ahb             : 簡單的 4-byte 週邊 IP 模型 (IntRx_O / IntTx_O 有延遲)
//  Interconnect (Arbiter / Decoder / Read-Data MUX) 未包含，testbench 為點對點連接。
// ============================================================================

// ---------------------------------------------------------------------------
//  AHB MASTER WRAPPER  (Read / Write 共用同一組 FSM，wr=1 為寫入)
// ---------------------------------------------------------------------------
module ahb_master_wrapper #(parameter MAXB = 8) (
    input  wire               hclk,
    input  wire               hresetn,
    // 使用者端 (DMA / CPU)
    input  wire               start,
    input  wire               wr,
    input  wire [31:0]        base_addr,
    input  wire [3:0]         len,          // beat 數 (1..MAXB)
    input  wire [2:0]         hsize_i,      // 0:byte 1:half 2:word
    input  wire [2:0]         hburst_i,
    input  wire [32*MAXB-1:0] wdata_flat,
    output reg  [32*MAXB-1:0] rdata_flat,   // HRDATA 存入 buffer
    output wire               irq,          // M_DONE : 中斷訊號 INTR
    output wire               err,          // M_ERR  : 回報 ERROR
    // AHB master 介面
    output wire [31:0]        haddr,
    output wire [1:0]         htrans,
    output wire               hwrite,
    output wire [2:0]         hsize,
    output wire [2:0]         hburst,
    output wire [31:0]        hwdata,
    input  wire [31:0]        hrdata,
    input  wire               hready,
    input  wire               hresp         // 0:OKAY 1:ERROR
);
    localparam M_IDLE = 3'd0, M_ADDR = 3'd1, M_BURST = 3'd2,
               M_LAST = 3'd3, M_DONE = 3'd4, M_ERR   = 3'd5;

    localparam HT_IDLE = 2'b00, HT_NONSEQ = 2'b10, HT_SEQ = 2'b11;

    reg [2:0]  state;
    reg [31:0] addr_q;
    reg [3:0]  cnt_a;          // 目前送出位址的 beat index
    reg [3:0]  cnt_d;          // 目前資料階段的 beat index
    reg [3:0]  len_q;
    reg        wr_q;
    reg [2:0]  hsize_q, hburst_q;

    wire [31:0] addr_inc = 32'd1 << hsize_q;

    // ---- Moore 輸出 --------------------------------------------------------
    assign htrans = (state == M_ADDR)  ? HT_NONSEQ :
                    (state == M_BURST) ? HT_SEQ    : HT_IDLE;
    assign haddr  = addr_q;
    assign hwrite = wr_q;
    assign hsize  = hsize_q;
    assign hburst = hburst_q;
    assign hwdata = (state == M_BURST || state == M_LAST)
                    ? wdata_flat[cnt_d*32 +: 32] : 32'd0;   // HREADY=0 時保持不變
    assign irq    = (state == M_DONE);
    assign err    = (state == M_ERR);

    // ---- 狀態轉移 ----------------------------------------------------------
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            state      <= M_IDLE;
            addr_q     <= 32'd0;
            cnt_a      <= 4'd0;
            cnt_d      <= 4'd0;
            len_q      <= 4'd0;
            wr_q       <= 1'b0;
            hsize_q    <= 3'd0;
            hburst_q   <= 3'd0;
            rdata_flat <= {32*MAXB{1'b0}};
        end else begin
            case (state)
            M_IDLE: if (start) begin                    // DMA -> Start, Length
                len_q    <= len;
                wr_q     <= wr;
                hsize_q  <= hsize_i;
                hburst_q <= hburst_i;
                addr_q   <= base_addr;
                cnt_a    <= 4'd0;
                cnt_d    <= 4'd0;
                state    <= M_ADDR;
            end

            M_ADDR: if (hready) begin                   // HREADY = 1
                addr_q <= addr_q + addr_inc;
                cnt_a  <= cnt_a + 4'd1;
                state  <= (len_q == 4'd1) ? M_LAST : M_BURST;
            end

            M_BURST: begin
                if (!hready && hresp) begin             // HREADY=0 && HRESP=ERR
                    state <= M_ERR;
                end else if (hready) begin              // HREADY=1 && HRESP=OK
                    if (!wr_q) rdata_flat[cnt_d*32 +: 32] <= hrdata;
                    cnt_d  <= cnt_d + 4'd1;
                    addr_q <= addr_q + addr_inc;        // 位址每個 BEAT 遞增
                    cnt_a  <= cnt_a + 4'd1;
                    if (cnt_a == len_q - 4'd1) state <= M_LAST;   // 最後一個位址送出
                end
            end

            M_LAST: begin
                if (!hready && hresp) begin
                    state <= M_ERR;
                end else if (hready) begin              // 存最後一筆 HRDATA
                    if (!wr_q) rdata_flat[cnt_d*32 +: 32] <= hrdata;
                    cnt_d <= cnt_d + 4'd1;
                    state <= M_DONE;
                end
            end

            M_DONE: state <= M_IDLE;                    // 傳輸結束

            M_ERR:  if (hready) state <= M_IDLE;        // 取消剩餘位址並回報 ERROR

            default: state <= M_IDLE;
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  AHB SLAVE WRAPPER  (Read FSM + Write FSM，後端接簡單 IP 匯流排)
// ---------------------------------------------------------------------------
module ahb_slave_wrapper (
    input  wire        hclk,
    input  wire        hresetn,
    // AHB slave 介面
    input  wire        hsel,
    input  wire        hready,        // 全域 HREADY (interconnect 回送)
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [31:0] hwdata,
    output wire [31:0] hrdata,
    output wire        hreadyout,
    output wire        hresp,
    // IP 端
    output wire        ip_stb,
    output wire        ip_we,
    output wire [1:0]  ip_adr,
    output wire [7:0]  ip_dat_o,      // 寫入 IP 的資料
    input  wire [7:0]  ip_dat_i,      // 由 IP 讀出的資料
    input  wire        int_rx,        // IntRx_O : IP 讀取資料就緒
    input  wire        int_tx         // IntTx_O : IP 可接受寫入
);
    wire rd_req = hsel && hready && htrans[1] && !hwrite;
    wire wr_req = hsel && hready && htrans[1] &&  hwrite;

    // ---------------- Read FSM ----------------
    localparam R_IDLE = 2'd0, R_WAIT = 2'd1, R_DATA = 2'd2;
    reg [1:0] rstate;
    reg [1:0] radr;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            rstate <= R_IDLE;
            radr   <= 2'd0;
        end else begin
            case (rstate)
            R_IDLE: if (rd_req) begin                   // HSEL && HREADY && HTRANS[1] && HWRITE=0
                radr   <= haddr[1:0];                   // LATCH HADDR[1:0]
                rstate <= R_WAIT;
            end
            R_WAIT: if (int_rx) rstate <= R_DATA;       // IntRx_O = 1
            R_DATA: if (hready) begin
                if (rd_req) begin                       // 下一筆資料位址有效
                    radr   <= haddr[1:0];
                    rstate <= R_WAIT;
                end else
                    rstate <= R_IDLE;                   // 下一筆不是讀
            end
            default: rstate <= R_IDLE;
            endcase
        end
    end

    wire rd_hro = (rstate != R_WAIT);
    wire rd_stb = (rstate == R_DATA);

    // ---------------- Write FSM ----------------
    localparam W_IDLE = 1'b0, W_DATA = 1'b1;
    reg wstate;
    reg [1:0] wadr;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            wstate <= W_IDLE;
            wadr   <= 2'd0;
        end else begin
            case (wstate)
            W_IDLE: if (wr_req) begin
                wadr   <= haddr[1:0];                   // LATCH HADDR[1:0]
                wstate <= W_DATA;
            end
            W_DATA: if (hready) begin
                if (wr_req) wadr <= haddr[1:0];         // 下一筆仍為寫入，留在 W_DATA
                else        wstate <= W_IDLE;
            end
            endcase
        end
    end

    wire wr_hro = (wstate == W_DATA) ? int_tx : 1'b1;   // HREADYOUT = IntTx_O
    wire wr_stb = (wstate == W_DATA) & int_tx;

    // ---------------- 輸出合併 ----------------
    assign hreadyout = rd_hro & wr_hro;
    assign hresp     = 1'b0;                            // OKAY
    assign hrdata    = (rstate == R_DATA) ? {24'b0, ip_dat_i} : 32'd0;
    assign ip_stb    = rd_stb | wr_stb;
    assign ip_we     = wr_stb;
    assign ip_adr    = (wstate == W_DATA) ? wadr : radr;
    assign ip_dat_o  = hwdata[7:0];
endmodule

// ---------------------------------------------------------------------------
//  簡單 IP 模型 : 4 bytes，讀取/寫入後會有等待週期
// ---------------------------------------------------------------------------
module ip_ahb (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       stb,
    input  wire       we,
    input  wire [1:0] adr,
    input  wire [7:0] dat_o,       // 來自 slave wrapper 的寫入資料
    output wire [7:0] dat_i,       // 送往 slave wrapper 的讀出資料
    output wire       int_rx,
    output wire       int_tx
);
    reg [7:0] mem [0:3];
    reg [2:0] rx_cnt, tx_cnt;
    assign int_rx = (rx_cnt == 0);
    assign int_tx = (tx_cnt == 0);
    assign dat_i  = mem[adr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem[0] <= 8'hA0; mem[1] <= 8'hA1; mem[2] <= 8'hA2; mem[3] <= 8'hA3;
            rx_cnt <= 3'd3;
            tx_cnt <= 3'd0;
        end else begin
            if (stb && !we)      rx_cnt <= 3'd1;
            else if (rx_cnt != 0) rx_cnt <= rx_cnt - 3'd1;

            if (stb && we) begin
                mem[adr] <= dat_o;
                tx_cnt   <= 3'd1;
            end else if (tx_cnt != 0)
                tx_cnt <= tx_cnt - 3'd1;
        end
    end
endmodule
