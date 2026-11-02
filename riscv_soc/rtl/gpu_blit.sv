`timescale 1ns/1ps
// Desktop 2D accelerator. ID register is 0x47505531 ("GPU1").
// Bit 0 of CTRL starts a fill or a copy. The walk is hardware, one pixel
// per AXI beat, and it always reaches DONE.
//
//  00 ID
//  04 STATUS  [0] busy [1] done [2] copy [3] alpha
//  08 START   write 1 to launch
//  10 FB_BASE destination framebuffer, byte address
//  14 SRC_BASE
//  18 PITCH   bytes per row
//  1C COLOR   destination color, or source color if copy==0
//  20 DST_XY  [15:0] x  [31:16] y
//  24 SIZE    [15:0] w  [31:16] h
//  28 SRC_XY
//  2C MODE    [0] copy  [1] alpha (copy must also be set)
module gpu_blit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  awaddr,
    input  wire        awvalid,
    output wire        awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output wire        wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [7:0]  araddr,
    input  wire        arvalid,
    output wire        arready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rvalid,
    input  wire        rready,
    output reg         m_awvalid,
    input  wire        m_awready,
    output reg  [31:0] m_awaddr,
    output reg         m_wvalid,
    input  wire        m_wready,
    output reg  [31:0] m_wdata,
    output wire        m_wlast,
    input  wire        m_bvalid,
    output wire        m_bready,
    output reg         m_arvalid,
    input  wire        m_arready,
    output reg  [31:0] m_araddr,
    input  wire        m_rvalid,
    output wire        m_rready,
    input  wire [31:0] m_rdata,
    output wire        irq
);
    localparam [31:0] ID = 32'h47505531;
    localparam [2:0] ST_IDLE=0, ST_RADDR=1, ST_RDATA=2, ST_WADDR=3, ST_WDATA=4, ST_BRESP=5;

    reg busy, done, mode_copy, mode_alpha;
    reg [31:0] fb_base, src_base, pitch, color;
    reg [15:0] x0, y0, rw, rh, sx, sy, px, py;
    reg [31:0] pix;
    reg [2:0] st;
    reg phase_dst;
    reg aw_got, w_got;
    reg [7:0] aw_q;
    reg [31:0] w_q;
    reg [3:0] ws_q;

    assign irq = done;
    assign awready = !aw_got;
    assign wready = !w_got;
    assign arready = !rvalid;
    assign m_wlast = 1'b1;
    assign m_bready = st == ST_BRESP;
    assign m_rready = st == ST_RDATA;

    wire [31:0] dst_addr = fb_base + ({{16{1'b0}}, y0} + {{16{1'b0}}, py}) * pitch
                                    + ({{16{1'b0}}, x0} + {{16{1'b0}}, px}) * 32'd4;
    wire [31:0] src_addr = src_base + ({{16{1'b0}}, sy} + {{16{1'b0}}, py}) * pitch
                                    + ({{16{1'b0}}, sx} + {{16{1'b0}}, px}) * 32'd4;

    function automatic [7:0] blend8(input [7:0] s, input [7:0] d, input [7:0] a);
        reg [15:0] acc;
        begin
            acc = (s * a) + (d * (8'd255 - a));
            blend8 = acc[15:8];
        end
    endfunction

    wire [31:0] blended = {8'hff,
                           blend8(pix[23:16], m_rdata[23:16], color[31:24]),
                           blend8(pix[15:8],  m_rdata[15:8],  color[31:24]),
                           blend8(pix[7:0],   m_rdata[7:0],   color[31:24])};

    task automatic next_pixel;
        begin
            if (px + 16'd1 == rw) begin
                px <= 16'd0;
                if (py + 16'd1 == rh) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st <= ST_IDLE;
                end else begin
                    py <= py + 16'd1;
                    st <= mode_copy ? ST_RADDR : ST_WADDR;
                    phase_dst <= 1'b0;
                end
            end else begin
                px <= px + 16'd1;
                st <= mode_copy ? ST_RADDR : ST_WADDR;
                phase_dst <= 1'b0;
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            bvalid <= 0; rvalid <= 0; bresp <= 0; rresp <= 0; rdata <= 0;
            busy <= 0; done <= 0; mode_copy <= 0; mode_alpha <= 0;
            fb_base <= 0; src_base <= 0; pitch <= 32'd5120; color <= 32'hff000000;
            x0 <= 0; y0 <= 0; rw <= 0; rh <= 0; sx <= 0; sy <= 0; px <= 0; py <= 0;
            pix <= 0; st <= ST_IDLE; phase_dst <= 0;
            m_awvalid <= 0; m_wvalid <= 0; m_arvalid <= 0;
            m_awaddr <= 0; m_araddr <= 0; m_wdata <= 0;
            aw_got <= 0; w_got <= 0; aw_q <= 0; w_q <= 0; ws_q <= 0;
        end else begin
            if (bvalid && bready) bvalid <= 1'b0;
            if (rvalid && rready) rvalid <= 1'b0;
            if (awvalid && awready) begin aw_got <= 1'b1; aw_q <= awaddr; end
            if (wvalid && wready) begin w_got <= 1'b1; w_q <= wdata; ws_q <= wstrb; end

            if (aw_got && w_got && !bvalid) begin
                aw_got <= 1'b0;
                w_got <= 1'b0;
                bvalid <= 1'b1;
                bresp <= 2'b00;
                if (!busy) case (aw_q)
                    8'h08: if (ws_q[0] && w_q[0] && rw != 0 && rh != 0) begin
                        busy <= 1'b1; done <= 1'b0; px <= 16'd0; py <= 16'd0; phase_dst <= 1'b0;
                        st <= mode_copy ? ST_RADDR : ST_WADDR;
                    end
                    8'h0c: done <= 1'b0;
                    8'h10: if (ws_q == 4'hf) fb_base <= w_q;
                    8'h14: if (ws_q == 4'hf) src_base <= w_q;
                    8'h18: if (ws_q == 4'hf) pitch <= w_q;
                    8'h1c: if (ws_q == 4'hf) color <= w_q;
                    8'h20: begin x0 <= w_q[15:0]; y0 <= w_q[31:16]; end
                    8'h24: begin rw <= w_q[15:0]; rh <= w_q[31:16]; end
                    8'h28: begin sx <= w_q[15:0]; sy <= w_q[31:16]; end
                    8'h2c: begin mode_copy <= w_q[0]; mode_alpha <= w_q[1]; end
                    default: bresp <= 2'b10;
                endcase
                else bresp <= 2'b10;
            end

            if (arvalid && arready) begin
                rvalid <= 1'b1;
                rresp <= 2'b00;
                case (araddr)
                    8'h00: rdata <= ID;
                    8'h04: rdata <= {28'b0, mode_alpha, mode_copy, done, busy};
                    8'h10: rdata <= fb_base;
                    8'h14: rdata <= src_base;
                    8'h18: rdata <= pitch;
                    8'h1c: rdata <= color;
                    default: begin rdata <= 32'b0; rresp <= 2'b10; end
                endcase
            end

            if (busy) case (st)
                ST_RADDR: begin
                    m_arvalid <= 1'b1;
                    m_araddr <= phase_dst ? dst_addr : src_addr;
                    if (m_arvalid && m_arready) begin
                        m_arvalid <= 1'b0;
                        st <= ST_RDATA;
                    end
                end
                ST_RDATA: begin
                    if (m_rvalid && m_rready) begin
                        if (!phase_dst && mode_alpha) begin
                            pix <= m_rdata;
                            phase_dst <= 1'b1;
                            st <= ST_RADDR;
                        end else begin
                            pix <= phase_dst ? blended : m_rdata;
                            st <= ST_WADDR;
                        end
                    end
                end
                ST_WADDR: begin
                    m_awvalid <= 1'b1;
                    m_awaddr <= dst_addr;
                    if (m_awvalid && m_awready) begin
                        m_awvalid <= 1'b0;
                        st <= ST_WDATA;
                    end
                end
                ST_WDATA: begin
                    m_wvalid <= 1'b1;
                    m_wdata <= mode_copy ? pix : color;
                    if (m_wvalid && m_wready) begin
                        m_wvalid <= 1'b0;
                        st <= ST_BRESP;
                    end
                end
                ST_BRESP: begin
                    if (m_bvalid && m_bready) next_pixel();
                end
                default: st <= ST_IDLE;
            endcase
        end
    end
endmodule
