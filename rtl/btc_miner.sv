`timescale 1ns/1ps
module btc_miner #(
    parameter integer LANES=1,
    parameter integer ROUNDS_PER_STAGE=2,
    parameter integer FIFO_DEPTH=8
) (
    input wire clk, reset, job_load, job_stop,
    input wire [255:0] midstate_i,
    input wire [95:0] tail_i,
    input wire [255:0] target_i,
    input wire [31:0] start_nonce_i, job_tag_i,
    input wire [LANES-1:0] result_pop,
    output wire [LANES-1:0] result_valid,
    output wire [LANES*64-1:0] result_front,
    output wire [LANES*8-1:0] result_count,
    output reg issuing, exhausted,
    output wire stalled,
    output reg [63:0] hashes_done
);
    localparam integer LATENCY=2*(64/ROUNDS_PER_STAGE);
    localparam integer PTR_W=$clog2(FIFO_DEPTH);
    localparam [255:0] IV=256'h6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19;
    reg [255:0] midstate, target;
    reg [95:0] tail;
    reg [31:0] tag;
    reg [32:0] base_nonce;
    reg [8:0] drain_left;
    wire flush = reset | job_load | job_stop;
    wire [LANES-1:0] queue_full, finished;
    wire advance = ~(|queue_full);
    assign stalled = ~advance;
    integer nfinished;
    integer f;
    always @* begin
        nfinished=0;
        for (f=0;f<LANES;f=f+1) nfinished=nfinished+{31'b0,finished[f]};
    end
    always @(posedge clk) begin
        if (reset) hashes_done<=0;
        else if (!job_load && !job_stop && advance) hashes_done<=hashes_done+{32'b0,nfinished[31:0]};
        if (reset || job_stop) begin
            issuing<=0; exhausted<=0; drain_left<=0; base_nonce<=0;
        end else if (job_load) begin
            midstate<=midstate_i; tail<=tail_i; target<=target_i; tag<=job_tag_i;
            base_nonce<={1'b0,start_nonce_i}; issuing<=1; exhausted<=0; drain_left<=0;
        end else if (advance) begin
            if (issuing) begin
                base_nonce<=base_nonce+LANES;
                if (base_nonce+LANES>=33'h100000000) begin
                    issuing<=0; drain_left<=9'(LATENCY);
                end
            end else if (drain_left!=0) begin
                drain_left<=drain_left-1'b1;
                if (drain_left==1) exhausted<=1;
            end
        end
    end
    function automatic [31:0] swap32(input [31:0] v);
        swap32={v[7:0],v[15:8],v[23:16],v[31:24]};
    endfunction
    genvar lane;
    generate for (lane=0;lane<LANES;lane=lane+1) begin: lanes
        wire [32:0] candidate=base_nonce+lane;
        wire valid_in=issuing && !candidate[32];
        wire [511:0] block1={tail,swap32(candidate[31:0]),32'h80000000,288'b0,64'd640};
        wire [255:0] digest1,digest2;
        wire v1,v2;
        sha256_pipeline #(.ROUNDS_PER_STAGE(ROUNDS_PER_STAGE)) first_hash (
            .clk(clk),.reset(flush),.ce(advance),.valid_i(valid_in),
            .init_state(midstate),.block_i(block1),.valid_o(v1),.digest_o(digest1));
        sha256_pipeline #(.ROUNDS_PER_STAGE(ROUNDS_PER_STAGE)) second_hash (
            .clk(clk),.reset(flush),.ce(advance),.valid_i(v1),
            .init_state(IV),.block_i({digest1,32'h80000000,160'b0,64'd256}),
            .valid_o(v2),.digest_o(digest2));
        reg [31:0] nonce_pipe[0:LATENCY-1];
        integer k;
        always @(posedge clk) if (advance) begin
            nonce_pipe[0]<=candidate[31:0];
            for (k=1;k<LATENCY;k=k+1) nonce_pipe[k]<=nonce_pipe[k-1];
        end
        wire [255:0] pow_value;
        genvar b;
        for (b=0;b<32;b=b+1) begin: pow_byte_order
            assign pow_value[b*8 +:8]=digest2[255-b*8 -:8];
        end
        reg [63:0] fifo[0:FIFO_DEPTH-1];
        reg [PTR_W-1:0] rdptr,wrptr;
        reg [7:0] count;
        wire pop=result_pop[lane] && count!=0;
        wire push=advance && v2 && pow_value<=target && !flush;
        // Backpressure freezes BOTH hash pipelines and their nonce tags. No
        // candidate is discarded when the software takes time to drain results.
        assign queue_full[lane]=(count==8'(FIFO_DEPTH)) && !pop;
        assign result_valid[lane]=(count!=0);
        assign result_front[lane*64 +:64]=fifo[rdptr];
        assign result_count[lane*8 +:8]=count;
        assign finished[lane]=v2;
        always @(posedge clk) begin
            if (flush) begin rdptr<=0; wrptr<=0; count<=0; end
            else begin
                case ({push,pop})
                    2'b10: count<=count+1'b1;
                    2'b01: count<=count-1'b1;
                    default: count<=count;
                endcase
                if (push) begin
                    fifo[wrptr]<={tag,nonce_pipe[LATENCY-1]}; wrptr<=wrptr+1'b1;
                end
                if (pop) rdptr<=rdptr+1'b1;
            end
        end
    end endgenerate
endmodule
