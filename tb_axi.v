`timescale 1ns/1ps
// iverilog -o axi.vvp axi_wrappers.v tb_axi.v && vvp axi.vvp && gtkwave axi.vcd
module tb_axi;
    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---- master 控制 ----
    reg         w_start = 0, r_start = 0;
    reg  [31:0] w_addr = 0, r_addr = 0;
    reg  [7:0]  w_len = 2, r_len = 4;
    reg  [3:0]  w_nb = 2;
    wire        w_done, w_err, r_done, r_err, rd_vld;
    wire [31:0] rd_data;

    // ---- AW/W/B ----
    wire [3:0]  awid, bid;  wire [31:0] awaddr; wire [7:0] awlen;
    wire [2:0]  awsize;     wire [1:0]  awburst; wire awvalid, awready;
    wire [31:0] wdata;      wire [3:0]  wstrb;   wire wlast, wvalid, wready;
    wire [1:0]  bresp;      wire bvalid, bready;
    // ---- AR/R ----
    wire [3:0]  arid, rid;  wire [31:0] araddr;  wire [7:0] arlen;
    wire [2:0]  arsize;     wire [1:0]  arburst; wire arvalid, arready;
    wire [31:0] rdata;      wire [1:0]  rresp;   wire rlast, rvalid, rready;
    // ---- IP ----
    wire        rd_stb, wr_stb, ack, int_rx, int_tx;
    wire [15:0] rd_adr, wr_adr;
    wire [31:0] ip_dout, wr_dat;

    axi_master_wr #(.MID(4'h1)) u_mw (
        .aclk(aclk), .aresetn(aresetn),
        .start(w_start), .addr_i(w_addr), .len_i(w_len), .nburst_i(w_nb),
        .wdata_seed(32'hA5A5_0000), .done(w_done), .err(w_err),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready));

    axi_slave_wr u_sw (
        .aclk(aclk), .aresetn(aresetn),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .ip_stb(wr_stb), .ip_adr(wr_adr), .ip_dat(wr_dat),
        .ack(ack), .int_tx(int_tx));

    axi_master_rd #(.MID(4'h1)) u_mr (
        .aclk(aclk), .aresetn(aresetn),
        .start(r_start), .addr_i(r_addr), .len_i(r_len),
        .rd_vld(rd_vld), .rd_data(rd_data), .done(r_done), .err(r_err),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready));

    axi_slave_rd u_sr (
        .aclk(aclk), .aresetn(aresetn),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .ip_stb(rd_stb), .ip_adr(rd_adr), .ip_dat(ip_dout),
        .ack(ack), .int_rx(int_rx));

    // 讀/寫 slave 共用一個 IP (testbench 中兩者不會同時存取)
    ip_axi u_ip (
        .clk(aclk), .rst_n(aresetn),
        .stb(rd_stb | wr_stb), .we(wr_stb),
        .adr(wr_stb ? wr_adr : rd_adr), .din(wr_dat),
        .dout(ip_dout), .ack(ack), .int_rx(int_rx), .int_tx(int_tx));

    integer n, errors;
    reg [31:0] exp_q;
    initial begin
        $dumpfile("axi.vcd");
        $dumpvars(0, tb_axi);
        errors = 0; n = 0;
        repeat (2) @(posedge aclk);
        #1 aresetn = 1;
        repeat (2) @(posedge aclk);

        // 寫入 : 2 個 burst x 2 beats  -> 0x4000_0000 ~ 0x4000_000C
        #1 w_addr = 32'h4000_0000; w_start = 1;
        @(posedge aclk); #1 w_start = 0;
        wait (w_done); @(posedge aclk);
        repeat (2) @(posedge aclk);

        // 讀回 : 1 個 burst x 4 beats
        #1 r_addr = 32'h4000_0000; r_start = 1;
        @(posedge aclk); #1 r_start = 0;
        wait (r_done); @(posedge aclk);
        repeat (3) @(posedge aclk);

        if (errors == 0 && n == 4) $display("AXI TEST PASS");
        else                       $display("AXI TEST FAIL errors=%0d beats=%0d", errors, n);
        $finish;
    end

    // 自動比對讀回資料
    always @(posedge aclk) if (rd_vld) begin
        exp_q = 32'hA5A5_0000 + n;
        if (rd_data !== exp_q) begin
            errors = errors + 1;
            $display("MISMATCH beat %0d: got %h exp %h", n, rd_data, exp_q);
        end
        n = n + 1;
    end
endmodule
