// ============================================================================
//  AXI4 Wrappers  (對應圖中 "AXI Read/Write Transaction Flow")
//    Read  : axi_master_rd  (M_IDLE/M_AR/M_R/M_DONE/M_ERR)
//            axi_slave_rd   (R_IDLE/R_WAIT/R_ACCESS/R_DATA)
//    Write : axi_master_wr  (M_IDLE/M_AW/M_W/M_B/M_DONE/M_ERR)
//            axi_slave_wr   (W_IDLE/W_DATA/W_ACCESS/W_RESP)
//    ip_axi: 簡單 IP 模型 (STB/WE/ADR/ACK/IntRx_O/IntTx_O)
//  Crossbar (Arbiter / Decoder / ID Tag Reordering) 未包含，testbench 為點對點連接。
// ============================================================================

// ---------------------------------------------------------------------------
//  MASTER READ FSM
// ---------------------------------------------------------------------------
module axi_master_rd #(parameter [3:0] MID = 4'h1) (
    input  wire        aclk, aresetn,
    input  wire        start,
    input  wire [31:0] addr_i,
    input  wire [7:0]  len_i,            // beat 數
    output wire        rd_vld,           // 每筆讀回資料有效
    output wire [31:0] rd_data,
    output wire        done,             // M_DONE : 觸發 DMA/CPU 中斷
    output wire        err,
    // AR
    output wire [3:0]  arid,
    output wire [31:0] araddr,
    output wire [7:0]  arlen,
    output wire [2:0]  arsize,
    output wire [1:0]  arburst,
    output wire        arvalid,
    input  wire        arready,
    // R
    input  wire [3:0]  rid,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready
);
    localparam M_IDLE = 3'd0, M_AR = 3'd1, M_R = 3'd2, M_DONE = 3'd3, M_ERR = 3'd4;
    reg [2:0]  state;
    reg [31:0] addr_q;
    reg [7:0]  len_q;

    assign arid    = MID;                 // ARID = Master ID
    assign araddr  = addr_q;              // ARADDR = Target Addr
    assign arlen   = len_q - 8'd1;        // ARLEN = Length - 1
    assign arsize  = 3'b010;              // 4 bytes / beat
    assign arburst = 2'b01;               // INCR
    assign arvalid = (state == M_AR);
    assign rready  = (state == M_R);
    assign rd_vld  = (state == M_R) && rvalid && (rresp == 2'b00);
    assign rd_data = rdata;
    assign done    = (state == M_DONE);
    assign err     = (state == M_ERR);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state  <= M_IDLE;
            addr_q <= 32'd0;
            len_q  <= 8'd0;
        end else begin
            case (state)
            M_IDLE: if (start) begin
                addr_q <= addr_i;
                len_q  <= len_i;
                state  <= M_AR;
            end
            M_AR: if (arvalid && arready) state <= M_R;             // 位址握手成功
            M_R: if (rvalid && rready) begin
                if (rresp != 2'b00)  state  <= M_ERR;               // RRESP != OKAY
                else if (rlast)      state  <= M_DONE;              // RLAST && OKAY
                else                 addr_q <= addr_q + 32'd4;      // 更新內部位址
            end
            M_DONE: state <= M_IDLE;
            M_ERR:  state <= M_IDLE;
            default: state <= M_IDLE;
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  SLAVE READ FSM
// ---------------------------------------------------------------------------
module axi_slave_rd (
    input  wire        aclk, aresetn,
    // AR
    input  wire [3:0]  arid,
    input  wire [31:0] araddr,
    input  wire [7:0]  arlen,
    input  wire        arvalid,
    output wire        arready,
    // R
    output wire [3:0]  rid,
    output wire [31:0] rdata,
    output wire [1:0]  rresp,
    output wire        rlast,
    output wire        rvalid,
    input  wire        rready,
    // IP
    output wire        ip_stb,
    output wire [15:0] ip_adr,
    input  wire [31:0] ip_dat,
    input  wire        ack,
    input  wire        int_rx
);
    localparam R_IDLE = 2'd0, R_WAIT = 2'd1, R_ACCESS = 2'd2, R_DATA = 2'd3;
    reg [1:0]  state;
    reg [3:0]  id_q;
    reg [31:0] adr_q, data_q;
    reg [7:0]  rem_q;
    reg        last_q;

    assign arready = (state == R_IDLE);
    assign ip_stb  = (state == R_ACCESS);          // STB=1, WE=0
    assign ip_adr  = adr_q[15:0];                  // ADR = Offset
    assign rvalid  = (state == R_DATA);
    assign rid     = id_q;                         // RID = ARID
    assign rdata   = data_q;                       // RDATA = IP_Data
    assign rresp   = 2'b00;                        // OKAY
    assign rlast   = last_q;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state <= R_IDLE; id_q <= 4'd0; adr_q <= 32'd0;
            data_q <= 32'd0; rem_q <= 8'd0; last_q <= 1'b0;
        end else begin
            case (state)
            R_IDLE: if (arvalid) begin                 // ARVALID && ARREADY
                id_q  <= arid;                         // 儲存 ARID / ARADDR / ARLEN
                adr_q <= araddr;
                rem_q <= arlen;
                state <= R_WAIT;
            end
            R_WAIT:   if (int_rx) state <= R_ACCESS;   // IntRx_O = 1 (IP Ready)
            R_ACCESS: if (ack) begin                   // ACK (Data Ready)
                data_q <= ip_dat;                      // Latch RDATA & RLAST
                last_q <= (rem_q == 8'd0);
                state  <= R_DATA;
            end
            R_DATA: if (rready) begin                  // RVALID && RREADY
                if (last_q) state <= R_IDLE;           // RLAST = 1
                else begin                             // RLAST = 0 (取下一筆)
                    rem_q <= rem_q - 8'd1;
                    adr_q <= adr_q + 32'd4;
                    state <= R_WAIT;
                end
            end
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  MASTER WRITE FSM  (支援多個 burst : M_B -> M_AW 迴圈)
// ---------------------------------------------------------------------------
module axi_master_wr #(parameter [3:0] MID = 4'h1) (
    input  wire        aclk, aresetn,
    input  wire        start,
    input  wire [31:0] addr_i,
    input  wire [7:0]  len_i,             // 每個 burst 的 beat 數
    input  wire [3:0]  nburst_i,          // burst 個數
    input  wire [31:0] wdata_seed,        // WDATA = seed + beat 序號
    output wire        done,
    output wire        err,
    // AW
    output wire [3:0]  awid,
    output wire [31:0] awaddr,
    output wire [7:0]  awlen,
    output wire [2:0]  awsize,
    output wire [1:0]  awburst,
    output wire        awvalid,
    input  wire        awready,
    // W
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,
    // B
    input  wire [3:0]  bid,
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);
    localparam M_IDLE = 3'd0, M_AW = 3'd1, M_W = 3'd2, M_B = 3'd3,
               M_DONE = 3'd4, M_ERR = 3'd5;
    reg [2:0]  state;
    reg [31:0] addr_q, seed_q, tot_q;
    reg [7:0]  len_q, beat_q;
    reg [3:0]  nb_q;

    assign awid    = MID;
    assign awaddr  = addr_q;
    assign awlen   = len_q - 8'd1;
    assign awsize  = 3'b010;
    assign awburst = 2'b01;                       // INCR
    assign awvalid = (state == M_AW);
    assign wvalid  = (state == M_W);
    assign wdata   = seed_q + tot_q;              // Out Data
    assign wstrb   = 4'hF;                        // Byte Enables
    assign wlast   = (beat_q == len_q - 8'd1);    // Final Beat
    assign bready  = (state == M_B);
    assign done    = (state == M_DONE);
    assign err     = (state == M_ERR);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state <= M_IDLE; addr_q <= 0; seed_q <= 0; tot_q <= 0;
            len_q <= 0; beat_q <= 0; nb_q <= 0;
        end else begin
            case (state)
            M_IDLE: if (start) begin
                addr_q <= addr_i; len_q <= len_i; nb_q <= nburst_i;
                seed_q <= wdata_seed; tot_q <= 32'd0;
                state  <= M_AW;
            end
            M_AW: if (awvalid && awready) begin        // 位址握手成功
                beat_q <= 8'd0;
                state  <= M_W;
            end
            M_W: if (wvalid && wready) begin
                tot_q <= tot_q + 32'd1;
                if (wlast) state <= M_B;               // WVALID && WREADY && WLAST
                else       beat_q <= beat_q + 8'd1;    // WVALID && WREADY && !WLAST
            end
            M_B: if (bvalid && bready) begin
                if (bresp != 2'b00) state <= M_ERR;    // BRESP != OKAY
                else if (nb_q > 4'd1) begin            // 尚有剩餘 burst
                    nb_q   <= nb_q - 4'd1;
                    addr_q <= addr_q + {22'd0, len_q, 2'b00};
                    state  <= M_AW;
                end else state <= M_DONE;              // 無剩餘 -> 寫入完全結束
            end
            M_DONE: state <= M_IDLE;
            M_ERR:  state <= M_IDLE;
            default: state <= M_IDLE;
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  SLAVE WRITE FSM
// ---------------------------------------------------------------------------
module axi_slave_wr (
    input  wire        aclk, aresetn,
    // AW
    input  wire [3:0]  awid,
    input  wire [31:0] awaddr,
    input  wire [7:0]  awlen,
    input  wire        awvalid,
    output wire        awready,
    // W
    input  wire [31:0] wdata,
    input  wire        wlast,
    input  wire        wvalid,
    output wire        wready,
    // B
    output wire [3:0]  bid,
    output wire [1:0]  bresp,
    output wire        bvalid,
    input  wire        bready,
    // IP
    output wire        ip_stb,
    output wire [15:0] ip_adr,
    output wire [31:0] ip_dat,
    input  wire        ack,
    input  wire        int_tx
);
    localparam W_IDLE = 2'd0, W_DATA = 2'd1, W_ACCESS = 2'd2, W_RESP = 2'd3;
    reg [1:0]  state;
    reg [3:0]  id_q;
    reg [31:0] adr_q, data_q;
    reg        last_q;

    assign awready = (state == W_IDLE);
    assign wready  = (state == W_DATA) && int_tx;   // WREADY = 1 (IntTx_O = 1)
    assign ip_stb  = (state == W_ACCESS);           // STB=1, WE=1
    assign ip_adr  = adr_q[15:0];
    assign ip_dat  = data_q;                        // DAT = WDATA
    assign bvalid  = (state == W_RESP);
    assign bid     = id_q;                          // BID = AWID
    assign bresp   = 2'b00;                         // OKAY

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state <= W_IDLE; id_q <= 0; adr_q <= 0; data_q <= 0; last_q <= 0;
        end else begin
            case (state)
            W_IDLE: if (awvalid) begin              // AWVALID && AWREADY
                id_q  <= awid;
                adr_q <= awaddr;
                state <= W_DATA;
            end
            W_DATA: if (wvalid && wready) begin     // 儲存 WDATA & WLAST
                data_q <= wdata;
                last_q <= wlast;
                state  <= W_ACCESS;
            end
            W_ACCESS: if (ack) begin
                if (last_q) state <= W_RESP;        // ACK && WLAST
                else begin                          // ACK && !WLAST (取下一筆)
                    adr_q <= adr_q + 32'd4;
                    state <= W_DATA;
                end
            end
            W_RESP: if (bready) state <= W_IDLE;    // BVALID && BREADY
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  簡單 IP 模型 : 16 words，ACK 於 STB 後一個週期回應
// ---------------------------------------------------------------------------
module ip_axi (
    input  wire        clk, rst_n,
    input  wire        stb, we,
    input  wire [15:0] adr,
    input  wire [31:0] din,
    output wire [31:0] dout,
    output wire        ack,
    output wire        int_rx,
    output wire        int_tx
);
    reg [31:0] mem [0:15];
    reg        ack_q;
    reg [2:0]  rx_cnt, tx_cnt;
    integer    k;
    assign ack    = ack_q;
    assign dout   = mem[adr[5:2]];
    assign int_rx = (rx_cnt == 0);
    assign int_tx = (tx_cnt == 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < 16; k = k + 1) mem[k] <= 32'hD000_0000 + k;
            ack_q <= 1'b0; rx_cnt <= 3'd3; tx_cnt <= 3'd0;
        end else begin
            ack_q <= stb & ~ack_q;
            if (stb && !we && ack_q)      rx_cnt <= 3'd2;
            else if (rx_cnt != 0)         rx_cnt <= rx_cnt - 3'd1;

            if (stb && we && ack_q) begin
                mem[adr[5:2]] <= din;
                tx_cnt        <= 3'd2;
            end else if (tx_cnt != 0)     tx_cnt <= tx_cnt - 3'd1;
        end
    end
endmodule
