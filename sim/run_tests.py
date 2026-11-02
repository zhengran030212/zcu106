#!/usr/bin/env python3
"""Generate hardware reference vectors with hashlib, then run real RTL simulation."""
import hashlib
import os
import struct
import subprocess
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"host"))
from btc_lottery.bitcoin import compress
HEADER=bytes.fromhex("01000000"+"00"*32+"3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a"+"29ab5f49ffff001d1dac2b7c")

def packed_state(header): return "".join("%08x"%v for v in compress(header[:64]))
def hashvalue(h,n):
    data=h+struct.pack("<I",n)
    return int.from_bytes(hashlib.sha256(hashlib.sha256(data).digest()).digest(),"little")

def bench(lanes):
    random_header=bytes(range(76))
    start=0xFFFFFFE8
    target=hashvalue(random_header,0xFFFFFFF9)
    check=""
    for lane in range(lanes):
        expected=[n for n in range(start+lane,1<<32,lanes) if hashvalue(random_header,n)<=target]
        for n in expected: check+=f"take({lane},32'h{n:08x},3);\n"
    return f"""
`timescale 1ns/1ps
module tb;
parameter RPS=2;
localparam L={lanes}; localparam LAT=128/RPS;
reg clk=0; always #5 clk=~clk;
reg reset=1,load=0,stop=0;
reg [255:0] midstate,target;
reg [95:0] tail;
reg [31:0] start_nonce,tag;
reg [L-1:0] pop=0;
wire [L-1:0] valid;
wire [L*64-1:0] front;
wire [L*8-1:0] counts;
wire issuing,exhausted,stalled;
wire [63:0] hashes;
btc_miner #(.LANES(L),.ROUNDS_PER_STAGE(RPS)) dut (
.clk(clk),.reset(reset),.job_load(load),.job_stop(stop),.midstate_i(midstate),.tail_i(tail),.target_i(target),
.start_nonce_i(start_nonce),.job_tag_i(tag),.result_pop(pop),.result_valid(valid),.result_front(front),
.result_count(counts),.issuing(issuing),.exhausted(exhausted),.stalled(stalled),.hashes_done(hashes));
task new_job;
begin @(negedge clk);load=1; @(negedge clk);load=0;end
endtask
task take(input integer lane,input [31:0] nonce,input [31:0] expected_tag);
integer timeout;
begin
 @(negedge clk); timeout=0;
 while (!valid[lane] && timeout<500) begin @(negedge clk);timeout=timeout+1;end
 if (!valid[lane]) $fatal(1,"missing result lane=%0d nonce=%h",lane,nonce);
 if (front[lane*64 +:64] !== {{expected_tag,nonce}})
   $fatal(1,"wrong result lane=%0d got=%h expected=%h:%h",lane,front[lane*64 +:64],expected_tag,nonce);
 pop[lane]=1; @(negedge clk);pop[lane]=0;
end endtask
integer i,j;
reg [63:0] before_hashes,paused;
initial begin
 repeat(4) @(negedge clk);reset=0;
 midstate=256'h{packed_state(HEADER)};tail=96'h{HEADER[64:76].hex()};
 target=256'h{(0xFFFF << 208):064x};start_nonce=32'd2083236890;tag=1;new_job();
 repeat(LAT+16) @(negedge clk);
 take(3%L,32'd2083236893,1);
 if (|valid) $fatal(1,"unexpected genesis result");
 @(negedge clk);stop=1;@(negedge clk);stop=0;
 // Near-wrap work: fill every lane queue, freeze the pipeline, then drain.
 before_hashes=hashes;
 target={{256{{1'b1}}}};start_nonce=32'hffffffe0;tag=2;new_job();
 repeat(LAT+24) @(negedge clk);
 if (!stalled) $fatal(1,"FIFO backpressure did not stall");
 paused=hashes;repeat(10) @(negedge clk);
 if (hashes!==paused) $fatal(1,"hash counter advances during stall");
 for(i=0;i<32;i=i+1) take(i%L,32'hffffffe0+i,2);
 repeat(LAT+5) @(negedge clk);
 if (!exhausted || |valid || hashes-before_hashes!=32)
   $fatal(1,"wrap/drain/count error exhausted=%b valid=%b hashes=%d",exhausted,valid,hashes-before_hashes);
 // Different header/midstate and an exact 256-bit inclusive target boundary.
 midstate=256'h{packed_state(random_header)};tail=96'h{random_header[64:76].hex()};
 target=256'h{target:064x};start_nonce=32'hffffffe8;tag=3;new_job();
 repeat(LAT+30) @(negedge clk);
 {check}
 repeat(8) @(negedge clk);
 if (!exhausted || |valid) $fatal(1,"target comparison or new-job flush error");
 // Replace a stalled job: no old tag may survive the flush.
 target={{256{{1'b1}}}};start_nonce=0;tag=4;new_job();
 repeat(LAT+20) @(negedge clk);
 if (!stalled) $fatal(1,"expected stalled old job");
 start_nonce=32'hffffffff;tag=5;new_job();
 repeat(LAT+5) @(negedge clk);
 take(0,32'hffffffff,5);
 if (|valid || !exhausted) $fatal(1,"flush/exhaustion lost alignment");
 $display("PASS miner lanes=%0d rounds_per_stage=%0d",L,RPS);$finish;
end
initial begin #1000000;$fatal(1,"simulation timed out");end
endmodule
"""

def main():
    out=ROOT/"build"/"sim";out.mkdir(parents=True,exist_ok=True)
    for lanes in (2,3):
        tb=out/f"tb_l{lanes}.sv";tb.write_text(bench(lanes))
        for rps in (1,2,4):
            exe=out/f"miner_l{lanes}_r{rps}.vvp"
            subprocess.run(["iverilog","-g2012","-s","tb","-P",f"tb.RPS={rps}","-o",str(exe),str(ROOT/"rtl/sha256_pipeline.sv"),str(ROOT/"rtl/btc_miner.sv"),str(tb)],check=True)
            subprocess.run(["vvp",str(exe)],check=True,timeout=45)
if __name__=="__main__": main()
