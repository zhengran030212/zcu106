`timescale 1ns/1ps
// SHA-256 compression pipeline. init_state must stay constant until all valid
// inputs have drained. A job change must assert reset. All registers share ce.
module sha256_pipeline #(
    parameter integer ROUNDS_PER_STAGE = 2
) (
    input wire clk, reset, ce,
    input wire valid_i,
    input wire [255:0] init_state,
    input wire [511:0] block_i,
    output wire valid_o,
    output wire [255:0] digest_o
);
    localparam integer STAGES = 64 / ROUNDS_PER_STAGE;
    localparam [2047:0] K = {
        32'h428a2f98,32'h71374491,32'hb5c0fbcf,32'he9b5dba5,
        32'h3956c25b,32'h59f111f1,32'h923f82a4,32'hab1c5ed5,
        32'hd807aa98,32'h12835b01,32'h243185be,32'h550c7dc3,
        32'h72be5d74,32'h80deb1fe,32'h9bdc06a7,32'hc19bf174,
        32'he49b69c1,32'hefbe4786,32'h0fc19dc6,32'h240ca1cc,
        32'h2de92c6f,32'h4a7484aa,32'h5cb0a9dc,32'h76f988da,
        32'h983e5152,32'ha831c66d,32'hb00327c8,32'hbf597fc7,
        32'hc6e00bf3,32'hd5a79147,32'h06ca6351,32'h14292967,
        32'h27b70a85,32'h2e1b2138,32'h4d2c6dfc,32'h53380d13,
        32'h650a7354,32'h766a0abb,32'h81c2c92e,32'h92722c85,
        32'ha2bfe8a1,32'ha81a664b,32'hc24b8b70,32'hc76c51a3,
        32'hd192e819,32'hd6990624,32'hf40e3585,32'h106aa070,
        32'h19a4c116,32'h1e376c08,32'h2748774c,32'h34b0bcb5,
        32'h391c0cb3,32'h4ed8aa4a,32'h5b9cca4f,32'h682e6ff3,
        32'h748f82ee,32'h78a5636f,32'h84c87814,32'h8cc70208,
        32'h90befffa,32'ha4506ceb,32'hbef9a3f7,32'hc67178f2
    };
    function automatic [31:0] ror(input [31:0] x, input integer n);
        ror = (x >> n) | (x << (32-n));
    endfunction
    function automatic [767:0] step(input [767:0] bundle, input integer round_idx);
        reg [31:0] a,b,c,d,e,f,g,h,t1,t2,next_w;
        reg [511:0] w;
        begin
            {a,b,c,d,e,f,g,h,w} = bundle;
            t1 = h + (ror(e,6)^ror(e,11)^ror(e,25))
                 + ((e&f)^((~e)&g)) + K[2047-round_idx*32 -: 32] + w[511:480];
            t2 = (ror(a,2)^ror(a,13)^ror(a,22)) + ((a&b)^(a&c)^(b&c));
            next_w = w[511:480] + (ror(w[479:448],7)^ror(w[479:448],18)^(w[479:448]>>3))
                     + w[223:192] + (ror(w[63:32],17)^ror(w[63:32],19)^(w[63:32]>>10));
            step = {t1+t2,a,b,c,d+t1,e,f,g,w[479:0],next_w};
        end
    endfunction
    wire [767:0] stage_in [0:STAGES];
    wire [STAGES:0] valid;
    assign stage_in[0] = {init_state,block_i};
    assign valid[0] = valid_i;
    genvar s;
    generate for (s=0; s<STAGES; s=s+1) begin: stages
        reg [767:0] data_q;
        reg valid_q;
        reg [767:0] next_data;
        integer u;
        always @* begin
            next_data = stage_in[s];
            for (u=0; u<ROUNDS_PER_STAGE; u=u+1)
                next_data = step(next_data,s*ROUNDS_PER_STAGE+u);
        end
        always @(posedge clk) begin
            if (reset) valid_q <= 1'b0;
            else if (ce) valid_q <= valid[s];
            if (ce) data_q <= next_data;
        end
        assign stage_in[s+1] = data_q;
        assign valid[s+1] = valid_q;
    end endgenerate
    genvar j;
    generate for (j=0; j<8; j=j+1) begin: feed_forward
        assign digest_o[255-j*32 -: 32] = stage_in[STAGES][767-j*32 -: 32]
                                          + init_state[255-j*32 -: 32];
    end endgenerate
    assign valid_o = valid[STAGES];
endmodule
