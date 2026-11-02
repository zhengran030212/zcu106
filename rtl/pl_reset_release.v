`timescale 1ns/1ps
// Release the AXI interconnect and miner from reset a few clocks after
// pl_clk0 runs. proc_sys_reset is still clocked with ext_reset_in and
// dcm_locked tied high, but its outputs must not be able to hold this
// domain in reset: after fpgautil, pl_resetn0 can stay low while pl_clk0
// keeps running. A stuck proc_sys_reset output is ignored once the fabric
// counter finishes.
module pl_reset_release (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET aresetn" *)
    input wire clk,
    (* X_INTERFACE_IGNORE = "true" *) input wire proc_peripheral_aresetn,
    (* X_INTERFACE_IGNORE = "true" *) input wire proc_interconnect_aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output reg aresetn = 1'b0
);
    reg [5:0] count = 6'd0;
    always @(posedge clk) begin
        if (count != 6'd32) begin
            count <= count + 6'd1;
            aresetn <= 1'b0;
        end else begin
            // 1'b1 forces release. The proc_sys_reset inputs stay in the
            // equation so a tied-off controller is part of the design, but a
            // low proc_aresetn cannot clear this OR.
            aresetn <= 1'b1 | (proc_peripheral_aresetn & proc_interconnect_aresetn);
        end
    end
endmodule
