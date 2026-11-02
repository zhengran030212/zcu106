`timescale 1ns/1ps
// GPIO-slot slave at 0x40000000 plus the framebuffer master.
// The 64-bit CVA6 bus is split into the 32-bit blit registers.
// Pixel reads and writes leave as 64-bit single beats for the DRAM arbiter.
module zcu106_display (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [4:0]  s_awid,
    input  wire [63:0] s_awaddr,
    input  wire [7:0]  s_awlen,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [63:0] s_wdata,
    input  wire [7:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output reg  [4:0]  s_bid,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [4:0]  s_arid,
    input  wire [63:0] s_araddr,
    input  wire [7:0]  s_arlen,
    input  wire [2:0]  s_arsize,
    input  wire        s_arvalid,
    output wire        s_arready,
    output reg  [4:0]  s_rid,
    output reg  [63:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rlast,
    output reg         s_rvalid,
    input  wire        s_rready,
    output wire [4:0]  m_awid,
    output wire [63:0] m_awaddr,
    output wire [7:0]  m_awlen,
    output wire [2:0]  m_awsize,
    output wire [1:0]  m_awburst,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [63:0] m_wdata,
    output wire [7:0]  m_wstrb,
    output wire        m_wlast,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [4:0]  m_arid,
    output wire [63:0] m_araddr,
    output wire [7:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [63:0] m_rdata,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,
    output wire        hsync,
    output wire        vsync,
    output wire        de,
    output wire [23:0] pixel
);
    localparam FB = 32'hBF000000;

    reg [7:0] g_awaddr;
    reg       g_awvalid;
    wire      g_awready;
    reg [31:0] g_wdata;
    reg [3:0]  g_wstrb;
    reg        g_wvalid;
    wire       g_wready;
    wire [1:0] g_bresp;
    wire       g_bvalid;
    reg        g_bready;
    reg [7:0]  g_araddr;
    reg        g_arvalid;
    wire       g_arready;
    wire [31:0] g_rdata;
    wire [1:0]  g_rresp;
    wire        g_rvalid;
    reg         g_rready;
    wire        g_mawvalid, g_mwvalid, g_marvalid;
    wire        g_mawready, g_mwready, g_mbvalid, g_marready, g_mrvalid;
    wire [31:0] g_mawaddr, g_maddr_w, g_maraddr, g_mrdata;
    wire        g_mbready, g_mrready;
    wire        f_arvalid, f_arready, f_rvalid, f_rready;
    wire [31:0] f_araddr, f_rdata;

    reg aw_hold, w_hold, wr_hi;
    reg [4:0] aw_id_q;
    reg [7:0] aw_addr_q, aw_len_q, wstrb_q;
    reg [63:0] wdata_q;
    reg ar_hold, rd_hi;
    reg [4:0] ar_id_q;
    reg [7:0] ar_addr_q, ar_len_q;
    reg [2:0] ar_size_q;
    reg [31:0] rd_lo;

    assign s_awready = !aw_hold;
    assign s_wready = !w_hold;
    assign s_arready = !ar_hold && !s_rvalid;

    wire [31:0] wdata_lane = wr_hi ? wdata_q[63:32] : wdata_q[31:0];
    wire [3:0]  wstrb_lane = wr_hi ? wstrb_q[7:4] : wstrb_q[3:0];
    wire        lane_hot = |wstrb_lane;

    reg mem_wr, mem_rd, mem_gpu;
    reg [31:0] mem_addr, mem_wdata;
    wire mem_grant_w = mem_wr && m_awready && m_wready;
    wire mem_grant_r = mem_rd && m_arready;

    assign m_awid = 5'd1;
    assign m_awaddr = {32'd0, mem_addr};
    assign m_awlen = 8'd0;
    assign m_awsize = 3'd2;
    assign m_awburst = 2'b01;
    assign m_awvalid = mem_wr;
    assign m_wdata = mem_addr[2] ? {mem_wdata, 32'd0} : {32'd0, mem_wdata};
    assign m_wstrb = mem_addr[2] ? 8'hF0 : 8'h0F;
    assign m_wlast = 1'b1;
    assign m_wvalid = mem_wr;
    assign m_bready = mem_wr;
    assign m_arid = 5'd1;
    assign m_araddr = {32'd0, mem_addr};
    assign m_arlen = 8'd0;
    assign m_arsize = 3'd2;
    assign m_arburst = 2'b01;
    assign m_arvalid = mem_rd;
    assign m_rready = mem_rd;

    gpu_blit i_gpu (
        .clk(clk), .rst_n(rst_n),
        .awaddr(g_awaddr), .awvalid(g_awvalid), .awready(g_awready),
        .wdata(g_wdata), .wstrb(g_wstrb), .wvalid(g_wvalid), .wready(g_wready),
        .bresp(g_bresp), .bvalid(g_bvalid), .bready(g_bready),
        .araddr(g_araddr), .arvalid(g_arvalid), .arready(g_arready),
        .rdata(g_rdata), .rresp(g_rresp), .rvalid(g_rvalid), .rready(g_rready),
        .m_awvalid(g_mawvalid), .m_awready(g_mawready), .m_awaddr(g_mawaddr),
        .m_wvalid(g_mwvalid), .m_wready(g_mwready), .m_wdata(g_maddr_w),
        .m_wlast(), .m_bvalid(g_mbvalid), .m_bready(g_mbready),
        .m_arvalid(g_marvalid), .m_arready(g_marready), .m_araddr(g_maraddr),
        .m_rvalid(g_mrvalid), .m_rready(g_mrready), .m_rdata(g_mrdata),
        .irq()
    );

    fb_scanout i_scan (
        .clk(clk), .rst_n(rst_n),
        .fb_base(FB), .pitch(32'd5120),
        .m_arvalid(f_arvalid), .m_arready(f_arready), .m_araddr(f_araddr),
        .m_rvalid(f_rvalid), .m_rready(f_rready), .m_rdata(f_rdata),
        .hsync(hsync), .vsync(vsync), .de(de), .pixel(pixel)
    );

    assign g_mawready = mem_wr && mem_gpu && m_awready;
    assign g_mwready = mem_wr && mem_gpu && m_wready;
    assign g_mbvalid = mem_wr && mem_gpu && m_bvalid;
    assign g_mbready = 1'b1;
    assign g_marready = mem_rd && mem_gpu && m_arready;
    assign g_mrvalid = mem_rd && mem_gpu && m_rvalid;
    assign g_mrdata = mem_addr[2] ? m_rdata[63:32] : m_rdata[31:0];
    assign f_arready = mem_rd && !mem_gpu && m_arready;
    assign f_rvalid = mem_rd && !mem_gpu && m_rvalid;
    assign f_rdata = mem_addr[2] ? m_rdata[63:32] : m_rdata[31:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_hold <= 0; w_hold <= 0; wr_hi <= 0;
            ar_hold <= 0; rd_hi <= 0;
            s_bvalid <= 0; s_rvalid <= 0; s_rlast <= 0;
            s_bresp <= 0; s_rresp <= 0; s_bid <= 0; s_rid <= 0; s_rdata <= 0;
            g_awvalid <= 0; g_wvalid <= 0; g_arvalid <= 0;
            g_bready <= 0; g_rready <= 0;
            mem_wr <= 0; mem_rd <= 0; mem_gpu <= 0;
            mem_addr <= 0; mem_wdata <= 0;
        end else begin
            g_bready <= 1'b0;
            g_rready <= 1'b0;
            if (s_bvalid && s_bready) s_bvalid <= 1'b0;
            if (s_rvalid && s_rready) s_rvalid <= 1'b0;

            if (s_awvalid && s_awready) begin
                aw_hold <= 1'b1;
                aw_id_q <= s_awid;
                aw_addr_q <= s_awaddr[7:0];
                aw_len_q <= s_awlen;
            end
            if (s_wvalid && s_wready) begin
                w_hold <= 1'b1;
                wdata_q <= s_wdata;
                wstrb_q <= s_wstrb;
            end
            if (s_arvalid && s_arready) begin
                ar_hold <= 1'b1;
                ar_id_q <= s_arid;
                ar_addr_q <= s_araddr[7:0];
                ar_len_q <= s_arlen;
                ar_size_q <= s_arsize;
                rd_hi <= 1'b0;
            end

            if (aw_hold && w_hold && !g_awvalid && !g_wvalid && !s_bvalid) begin
                if (aw_len_q != 0) begin
                    aw_hold <= 0; w_hold <= 0;
                    s_bvalid <= 1; s_bid <= aw_id_q; s_bresp <= 2'b10;
                end else if (!lane_hot) begin
                    wr_hi <= 1'b1;
                    if (wr_hi || !(|wstrb_q[7:4])) begin
                        aw_hold <= 0; w_hold <= 0; wr_hi <= 0;
                        s_bvalid <= 1; s_bid <= aw_id_q; s_bresp <= 2'b00;
                    end
                end else begin
                    g_awvalid <= 1;
                    g_awaddr <= {aw_addr_q[7:3], wr_hi, 2'b00};
                    g_wvalid <= 1;
                    g_wdata <= wdata_lane;
                    g_wstrb <= wstrb_lane;
                end
            end
            if (g_awvalid && g_awready) g_awvalid <= 0;
            if (g_wvalid && g_wready) g_wvalid <= 0;
            if (g_bvalid) begin
                g_bready <= 1;
                if (!wr_hi && |wstrb_q[7:4]) wr_hi <= 1;
                else begin
                    aw_hold <= 0; w_hold <= 0; wr_hi <= 0;
                    s_bvalid <= 1; s_bid <= aw_id_q; s_bresp <= g_bresp;
                end
            end

            if (ar_hold && !g_arvalid && !s_rvalid) begin
                if (ar_len_q != 0) begin
                    ar_hold <= 0;
                    s_rvalid <= 1; s_rlast <= 1; s_rid <= ar_id_q;
                    s_rresp <= 2'b10; s_rdata <= 0;
                end else begin
                    g_arvalid <= 1;
                    g_araddr <= {ar_addr_q[7:3], rd_hi, 2'b00};
                end
            end
            if (g_arvalid && g_arready) g_arvalid <= 0;
            if (g_rvalid) begin
                g_rready <= 1;
                if (ar_size_q == 3'd3 && !rd_hi) begin
                    rd_lo <= g_rdata;
                    rd_hi <= 1;
                end else begin
                    ar_hold <= 0; rd_hi <= 0;
                    s_rvalid <= 1; s_rlast <= 1; s_rid <= ar_id_q; s_rresp <= g_rresp;
                    s_rdata <= (ar_size_q == 3'd3) ? {g_rdata, rd_lo}
                             : rd_hi ? {g_rdata, 32'd0} : {32'd0, g_rdata};
                end
            end

            if (!mem_wr && g_mawvalid && g_mwvalid) begin
                mem_wr <= 1; mem_gpu <= 1;
                mem_addr <= g_mawaddr; mem_wdata <= g_maddr_w;
            end else if (mem_wr && m_bvalid) begin
                mem_wr <= 0; mem_gpu <= 0;
            end

            if (!mem_rd && !mem_wr && g_marvalid) begin
                mem_rd <= 1; mem_gpu <= 1; mem_addr <= g_maraddr;
            end else if (!mem_rd && !mem_wr && !g_marvalid && f_arvalid) begin
                mem_rd <= 1; mem_gpu <= 0; mem_addr <= f_araddr;
            end else if (mem_rd && m_rvalid) begin
                mem_rd <= 0;
            end
        end
    end
endmodule
