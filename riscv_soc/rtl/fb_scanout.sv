`timescale 1ns/1ps
// Reads a 1280x800 A8R8G8B8 framebuffer and emits display timing.
// The pixel source is the same memory the blit engine writes.
module fb_scanout (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] fb_base,
    input  wire [31:0] pitch,
    output reg         m_arvalid,
    input  wire        m_arready,
    output reg  [31:0] m_araddr,
    input  wire        m_rvalid,
    output wire        m_rready,
    input  wire [31:0] m_rdata,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg  [23:0] pixel
);
    localparam H_VISIBLE = 1280;
    localparam H_FRONT   = 48;
    localparam H_SYNC    = 32;
    localparam H_BACK    = 80;
    localparam H_TOTAL   = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
    localparam V_VISIBLE = 800;
    localparam V_FRONT   = 3;
    localparam V_SYNC    = 6;
    localparam V_BACK    = 14;
    localparam V_TOTAL   = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

    reg [11:0] hx, hy;
    reg [31:0] line_addr;
    reg        fetching;

    assign m_rready = 1'b1;

    wire visible = hx < H_VISIBLE && hy < V_VISIBLE;

    always @(posedge clk) begin
        if (!rst_n) begin
            hx <= 0; hy <= 0; line_addr <= 0;
            hsync <= 0; vsync <= 0; de <= 0; pixel <= 0;
            m_arvalid <= 0; m_araddr <= 0; fetching <= 0;
        end else begin
            de <= visible;
            hsync <= (hx >= H_VISIBLE + H_FRONT) && (hx < H_VISIBLE + H_FRONT + H_SYNC);
            vsync <= (hy >= V_VISIBLE + V_FRONT) && (hy < V_VISIBLE + V_FRONT + V_SYNC);
            if (m_rvalid) pixel <= m_rdata[23:0];

            if (visible && !fetching) begin
                m_arvalid <= 1'b1;
                m_araddr <= fb_base + line_addr + (hx * 32'd4);
                fetching <= 1'b1;
            end
            if (m_arvalid && m_arready) m_arvalid <= 1'b0;
            if (m_rvalid) fetching <= 1'b0;

            if (hx + 12'd1 == H_TOTAL) begin
                hx <= 0;
                if (hy + 12'd1 == V_TOTAL) begin
                    hy <= 0;
                    line_addr <= 0;
                end else begin
                    hy <= hy + 12'd1;
                    if (hy + 12'd1 < V_VISIBLE) line_addr <= line_addr + pitch;
                end
            end else hx <= hx + 12'd1;
        end
    end
endmodule
