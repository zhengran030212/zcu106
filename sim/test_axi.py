#!/usr/bin/env python3
import subprocess
from pathlib import Path
from run_tests import HEADER,packed_state
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/"build/sim";out.mkdir(parents=True,exist_ok=True)
state=packed_state(HEADER)
writes=""
for i in range(8): writes+=f"wr(12'h{0x40+4*i:03x},32'h{state[i*8:i*8+8]},4'hf,{i%3});\n"
for i in range(3): writes+=f"wr(12'h{0x60+4*i:03x},32'h{HEADER[64+4*i:68+4*i].hex()},4'hf,0);\n"
for i in range(8): writes+=f"wr(12'h{0x80+4*i:03x},32'h{((0xffff<<208)>>(i*32))&0xffffffff:08x},4'hf,0);\n"
tb=f"""
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg resetn=0;
reg [11:0] awaddr=0,araddr=0;
reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
reg [31:0] wdata=0;
reg [3:0] wstrb=0;
wire awready,wready,bvalid,arready,rvalid;
wire [1:0] bresp,rresp;
wire [31:0] rdata;
btc_axi #(.LANES(1),.ROUNDS_PER_STAGE(4)) dut (
.s_axi_aclk(clk),.s_axi_aresetn(resetn),.s_axi_awaddr(awaddr),.s_axi_awprot(3'b0),
.s_axi_awvalid(awvalid),.s_axi_awready(awready),.s_axi_wdata(wdata),.s_axi_wstrb(wstrb),
.s_axi_wvalid(wvalid),.s_axi_wready(wready),.s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
.s_axi_araddr(araddr),.s_axi_arprot(3'b0),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
task wr(input [11:0] a,input [31:0] d,input [3:0] s,input integer order);
begin
 @(negedge clk);awaddr=a;wdata=d;wstrb=s;
 if(order==1) begin
   awvalid=1;@(negedge clk);awvalid=0;repeat(3) @(negedge clk);
   wvalid=1;@(negedge clk);wvalid=0;
 end else if(order==2) begin
   wvalid=1;@(negedge clk);wvalid=0;repeat(3) @(negedge clk);
   awvalid=1;@(negedge clk);awvalid=0;
 end else begin
   awvalid=1;wvalid=1;@(negedge clk);awvalid=0;wvalid=0;
 end
 while(!bvalid) @(negedge clk);
 if(bresp!=0) $fatal(1,"AXI write failed addr=%h resp=%b",a,bresp);
 repeat(3) begin @(negedge clk);if(!bvalid) $fatal(1,"lost BVALID under backpressure");end
 bready=1;@(negedge clk);bready=0;
end endtask
task rd(input [11:0] a,input [31:0] expected,input [1:0] response);
reg [31:0] hold_data;
begin
 @(negedge clk);araddr=a;arvalid=1;@(negedge clk);arvalid=0;
 while(!rvalid) @(negedge clk);
 hold_data=rdata;
 if(rresp!==response || rdata!==expected) $fatal(1,"AXI read addr=%h got=%h/%h expected=%h/%h",a,rdata,rresp,expected,response);
 repeat(3) begin @(negedge clk);if(!rvalid || rdata!==hold_data) $fatal(1,"unstable read response");end
 rready=1;@(negedge clk);rready=0;
end endtask
initial begin
 repeat(4) @(negedge clk);resetn=1;
 rd(0,32'h42544331,0);rd(4,32'h00010000,0);rd(12'h3fc,0,2);
 wr(12'h040,32'h11223344,4'hf,1);
 wr(12'h040,32'haabbccdd,4'b0101,2);
 rd(12'h040,32'h11bb33dd,0);
 {writes}
 wr(12'h018,32'h98765432,4'hf,1);wr(12'h01c,32'd2083236892,4'hf,2);
 wr(12'h008,1,4'hf,0);
 repeat(64) @(negedge clk);
 rd(12'h02c,1,0);rd(12'h030,32'd2083236893,0);rd(12'h034,32'h98765432,0);
 wr(12'h038,1,4'hf,0);rd(12'h02c,0,0);
 wr(12'h008,2,4'hf,0);rd(12'h00c,0,0);
 $display("PASS AXI-Lite independent AW/W, strobes, backpressure, error response and golden nonce");$finish;
end
initial begin #200000;$fatal(1,"AXI simulation timed out");end
endmodule
"""
path=out/"tb_axi.sv";path.write_text(tb)
exe=out/"axi.vvp"
subprocess.run(["iverilog","-g2012","-s","tb","-o",str(exe),str(ROOT/"rtl/btc_axi.v"),str(ROOT/"rtl/btc_miner.sv"),str(ROOT/"rtl/sha256_pipeline.sv"),str(path)],check=True)
subprocess.run(["vvp",str(exe)],check=True,timeout=45)
