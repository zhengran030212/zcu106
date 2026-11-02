`timescale 1ns/1ps
// Two 64-bit AXI masters, one slave. The owner keeps the channel until the
// burst completes, so a CPU line fill cannot be split by a framebuffer beat.
module zcu106_axi_arb (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [4:0]  a_awid,
    input  wire [63:0] a_awaddr,
    input  wire [7:0]  a_awlen,
    input  wire [2:0]  a_awsize,
    input  wire [1:0]  a_awburst,
    input  wire        a_awvalid,
    output wire        a_awready,
    input  wire [63:0] a_wdata,
    input  wire [7:0]  a_wstrb,
    input  wire        a_wlast,
    input  wire        a_wvalid,
    output wire        a_wready,
    output wire [4:0]  a_bid,
    output wire [1:0]  a_bresp,
    output wire        a_bvalid,
    input  wire        a_bready,
    input  wire [4:0]  a_arid,
    input  wire [63:0] a_araddr,
    input  wire [7:0]  a_arlen,
    input  wire [2:0]  a_arsize,
    input  wire [1:0]  a_arburst,
    input  wire        a_arvalid,
    output wire        a_arready,
    output wire [4:0]  a_rid,
    output wire [63:0] a_rdata,
    output wire [1:0]  a_rresp,
    output wire        a_rlast,
    output wire        a_rvalid,
    input  wire        a_rready,
    input  wire [4:0]  b_awid,
    input  wire [63:0] b_awaddr,
    input  wire [7:0]  b_awlen,
    input  wire [2:0]  b_awsize,
    input  wire [1:0]  b_awburst,
    input  wire        b_awvalid,
    output wire        b_awready,
    input  wire [63:0] b_wdata,
    input  wire [7:0]  b_wstrb,
    input  wire        b_wlast,
    input  wire        b_wvalid,
    output wire        b_wready,
    output wire [4:0]  b_bid,
    output wire [1:0]  b_bresp,
    output wire        b_bvalid,
    input  wire        b_bready,
    input  wire [4:0]  b_arid,
    input  wire [63:0] b_araddr,
    input  wire [7:0]  b_arlen,
    input  wire [2:0]  b_arsize,
    input  wire [1:0]  b_arburst,
    input  wire        b_arvalid,
    output wire        b_arready,
    output wire [4:0]  b_rid,
    output wire [63:0] b_rdata,
    output wire [1:0]  b_rresp,
    output wire        b_rlast,
    output wire        b_rvalid,
    input  wire        b_rready,
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
    input  wire [4:0]  m_bid,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [4:0]  m_arid,
    output wire [63:0] m_araddr,
    output wire [7:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [4:0]  m_rid,
    input  wire [63:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready
);
    reg aw_lock, aw_sel, w_lock, w_sel, b_lock, b_sel;
    reg ar_lock, ar_sel, r_lock, r_sel;

    wire aw_pick = a_awvalid || b_awvalid;
    wire aw_choice = a_awvalid ? 1'b0 : 1'b1;
    wire aw_owner = aw_lock ? aw_sel : aw_choice;
    wire ar_pick = a_arvalid || b_arvalid;
    wire ar_choice = a_arvalid ? 1'b0 : 1'b1;
    wire ar_owner = ar_lock ? ar_sel : ar_choice;

    assign m_awvalid = aw_pick && !b_lock;
    assign m_awid    = aw_owner ? b_awid    : a_awid;
    assign m_awaddr  = aw_owner ? b_awaddr  : a_awaddr;
    assign m_awlen   = aw_owner ? b_awlen   : a_awlen;
    assign m_awsize  = aw_owner ? b_awsize  : a_awsize;
    assign m_awburst = aw_owner ? b_awburst : a_awburst;
    assign a_awready = m_awready && m_awvalid && !aw_owner;
    assign b_awready = m_awready && m_awvalid && aw_owner;

    assign m_wvalid = w_lock && (w_sel ? b_wvalid : a_wvalid);
    assign m_wdata  = w_sel ? b_wdata : a_wdata;
    assign m_wstrb  = w_sel ? b_wstrb : a_wstrb;
    assign m_wlast  = w_sel ? b_wlast : a_wlast;
    assign a_wready = m_wready && m_wvalid && !w_sel;
    assign b_wready = m_wready && m_wvalid && w_sel;

    assign a_bvalid = m_bvalid && b_lock && !b_sel;
    assign b_bvalid = m_bvalid && b_lock && b_sel;
    assign a_bid = m_bid;
    assign b_bid = m_bid;
    assign a_bresp = m_bresp;
    assign b_bresp = m_bresp;
    assign m_bready = b_lock && (b_sel ? b_bready : a_bready);

    assign m_arvalid = ar_pick && !r_lock;
    assign m_arid    = ar_owner ? b_arid    : a_arid;
    assign m_araddr  = ar_owner ? b_araddr  : a_araddr;
    assign m_arlen   = ar_owner ? b_arlen   : a_arlen;
    assign m_arsize  = ar_owner ? b_arsize  : a_arsize;
    assign m_arburst = ar_owner ? b_arburst : a_arburst;
    assign a_arready = m_arready && m_arvalid && !ar_owner;
    assign b_arready = m_arready && m_arvalid && ar_owner;

    assign a_rvalid = m_rvalid && r_lock && !r_sel;
    assign b_rvalid = m_rvalid && r_lock && r_sel;
    assign a_rid = m_rid;
    assign b_rid = m_rid;
    assign a_rdata = m_rdata;
    assign b_rdata = m_rdata;
    assign a_rresp = m_rresp;
    assign b_rresp = m_rresp;
    assign a_rlast = m_rlast;
    assign b_rlast = m_rlast;
    assign m_rready = r_lock && (r_sel ? b_rready : a_rready);

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_lock <= 0; w_lock <= 0; b_lock <= 0;
            ar_lock <= 0; r_lock <= 0;
            aw_sel <= 0; w_sel <= 0; b_sel <= 0; ar_sel <= 0; r_sel <= 0;
        end else begin
            if (m_awvalid && m_awready) begin
                aw_lock <= 1;
                aw_sel <= aw_owner;
                if (!w_lock) begin
                    w_lock <= 1;
                    w_sel <= aw_owner;
                end
                if (!b_lock) begin
                    b_lock <= 1;
                    b_sel <= aw_owner;
                end
            end
            if (m_wvalid && m_wready && m_wlast) w_lock <= 0;
            if (m_bvalid && m_bready) begin
                b_lock <= 0;
                aw_lock <= 0;
            end
            if (m_arvalid && m_arready) begin
                ar_lock <= 1;
                ar_sel <= ar_owner;
                if (!r_lock) begin
                    r_lock <= 1;
                    r_sel <= ar_owner;
                end
            end
            if (m_rvalid && m_rready && m_rlast) begin
                r_lock <= 0;
                ar_lock <= 0;
            end
        end
    end
endmodule
