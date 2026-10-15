`timescale 1ns/1ps
// iverilog -o ahb.vvp ahb_wrappers.v tb_ahb.v && vvp ahb.vvp && gtkwave ahb.vcd
module tb_ahb;
    reg hclk = 0, hresetn = 0;
    always #5 hclk = ~hclk;

    reg         start = 0, wr = 0;
    reg  [31:0] base_addr = 0;
    reg  [3:0]  len = 4;
    reg  [255:0] wdata_flat;
    wire [255:0] rdata_flat;
    wire        irq, err;

    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hready, hresp;
    wire [2:0]  hsize, hburst;

    wire        ip_stb, ip_we, int_rx, int_tx;
    wire [1:0]  ip_adr;
    wire [7:0]  ip_dat_o, ip_dat_i;

    ahb_master_wrapper #(.MAXB(8)) u_m (
        .hclk(hclk), .hresetn(hresetn),
        .start(start), .wr(wr), .base_addr(base_addr), .len(len),
        .hsize_i(3'd0), .hburst_i(3'd3),              // byte, INCR4
        .wdata_flat(wdata_flat), .rdata_flat(rdata_flat),
        .irq(irq), .err(err),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hsize(hsize), .hburst(hburst), .hwdata(hwdata),
        .hrdata(hrdata), .hready(hready), .hresp(hresp));

    ahb_slave_wrapper u_s (
        .hclk(hclk), .hresetn(hresetn),
        .hsel(1'b1), .hready(hready),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hwdata(hwdata),
        .hrdata(hrdata), .hreadyout(hready), .hresp(hresp),
        .ip_stb(ip_stb), .ip_we(ip_we), .ip_adr(ip_adr),
        .ip_dat_o(ip_dat_o), .ip_dat_i(ip_dat_i),
        .int_rx(int_rx), .int_tx(int_tx));

    ip_ahb u_ip (
        .clk(hclk), .rst_n(hresetn),
        .stb(ip_stb), .we(ip_we), .adr(ip_adr),
        .dat_o(ip_dat_o), .dat_i(ip_dat_i),
        .int_rx(int_rx), .int_tx(int_tx));

    task xfer(input w, input [31:0] a);
    begin
        @(posedge hclk); #1;
        wr = w; base_addr = a; start = 1;
        @(posedge hclk); #1;
        start = 0;
        wait (irq);
        @(posedge hclk); #1;
    end
    endtask

    integer i, errors;
    initial begin
        $dumpfile("ahb.vcd");
        $dumpvars(0, tb_ahb);
        wdata_flat = {128'd0, 32'h44, 32'h33, 32'h22, 32'h11};
        errors = 0;
        repeat (2) @(posedge hclk);
        #1 hresetn = 1;
        repeat (2) @(posedge hclk);

        xfer(1'b1, 32'h1000_0000);      // INCR4 write : 11 22 33 44
        repeat (2) @(posedge hclk);
        xfer(1'b0, 32'h1000_0000);      // INCR4 read back
        repeat (3) @(posedge hclk);

        for (i = 0; i < 4; i = i + 1)
            if (rdata_flat[i*32 +: 8] !== wdata_flat[i*32 +: 8]) begin
                errors = errors + 1;
                $display("MISMATCH beat %0d: got %h exp %h", i,
                         rdata_flat[i*32 +: 8], wdata_flat[i*32 +: 8]);
            end
        if (errors == 0) $display("AHB TEST PASS");
        else             $display("AHB TEST FAIL (%0d)", errors);
        $finish;
    end
endmodule
