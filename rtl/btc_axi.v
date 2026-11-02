`timescale 1ns/1ps
module btc_axi #(
    parameter integer LANES=1,
    parameter integer ROUNDS_PER_STAGE=2
) (
    (* X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input wire s_axi_aclk,
    (* X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *) input wire s_axi_aresetn,
    input wire [11:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output reg [1:0] s_axi_bresp = 2'b00, output reg s_axi_bvalid = 1'b0, input wire s_axi_bready,
    input wire [11:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata = 32'd0, output reg [1:0] s_axi_rresp = 2'b00,
    output reg s_axi_rvalid = 1'b0, input wire s_axi_rready
);
    // An incomplete AW/W pair must still produce BVALID. 256 clocks at 100 MHz
    // is far longer than a legal AXI-Lite address/data split on this PS, and
    // short enough that a missing beat cannot stall the master forever.
    localparam integer BEAT_BOUND = 256;
    reg awfull=0,wfull=0;
    reg [8:0] aw_wait=0,w_wait=0;
    reg [11:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    reg [255:0] midstate,target;
    reg [95:0] tail;
    reg [31:0] start_nonce,tag,selected;
    reg job_load,job_stop;
    reg [LANES-1:0] pop;
    wire [LANES-1:0] valid;
    wire [LANES*64-1:0] front;
    wire [LANES*8-1:0] counts;
    wire issuing,exhausted,stalled;
    wire [63:0] hashes;
    reg [31:0] hashes_hi_snapshot;
    btc_miner #(.LANES(LANES),.ROUNDS_PER_STAGE(ROUNDS_PER_STAGE)) miner (
        .clk(s_axi_aclk),.reset(!s_axi_aresetn),.job_load(job_load),.job_stop(job_stop),
        .midstate_i(midstate),.tail_i(tail),.target_i(target),
        .start_nonce_i(start_nonce),.job_tag_i(tag),.result_pop(pop),
        .result_valid(valid),.result_front(front),.result_count(counts),
        .issuing(issuing),.exhausted(exhausted),.stalled(stalled),.hashes_done(hashes));
    assign s_axi_awready=!awfull && !s_axi_bvalid;
    assign s_axi_wready=!wfull && !s_axi_bvalid;
    assign s_axi_arready=!s_axi_rvalid;
    function automatic [31:0] merge(input [31:0] oldv,input [31:0] newv,input [3:0] strb);
        integer i;
        begin
            merge=oldv;
            for (i=0;i<4;i=i+1) if (strb[i]) merge[i*8 +:8]=newv[i*8 +:8];
        end
    endfunction
    reg [31:0] read_data;
    reg [1:0] read_resp;
    integer r;
    always @* begin
        read_data=0; read_resp=0;
        case (s_axi_araddr)
            12'h000: read_data=32'h42544331;
            12'h004: read_data=32'h00010000;
            12'h008: read_data=0;
            12'h00c: read_data={28'b0,(|valid),stalled,exhausted,issuing};
            12'h010: read_data=LANES;
            12'h014: read_data=ROUNDS_PER_STAGE;
            12'h018: read_data=tag;
            12'h01c: read_data=start_nonce;
            12'h020: read_data=hashes[31:0];
            12'h024: read_data=hashes_hi_snapshot;
            12'h028: read_data=selected;
            12'h02c: if (selected<LANES) read_data={24'b0,counts[selected*8 +:8]};
            12'h030: if (selected<LANES) read_data=front[selected*64 +:32];
            12'h034: if (selected<LANES) read_data=front[selected*64+32 +:32];
            12'h038: read_data=0;
            default: begin
                read_resp=2'b10;
                for (r=0;r<8;r=r+1) begin
                    if ({20'b0,s_axi_araddr}==32'h040+r*4) begin read_data=midstate[255-r*32 -:32]; read_resp=0; end
                    if ({20'b0,s_axi_araddr}==32'h080+r*4) begin read_data=target[r*32 +:32]; read_resp=0; end
                end
                for (r=0;r<3;r=r+1)
                    if ({20'b0,s_axi_araddr}==32'h060+r*4) begin read_data=tail[95-r*32 -:32]; read_resp=0; end
            end
        endcase
    end
    integer w;
    // Handshake state is intentionally NOT cleared by s_axi_aresetn. A stuck
    // reset used to present AWREADY/ARREADY while forcing BVALID/RVALID low,
    // and the PS AXI master has no timeout. CSR state still clears on reset.
    // Once BVALID/RVALID is high it stays until the master accepts it.
    always @(posedge s_axi_aclk) begin
        job_load<=0; job_stop<=0; pop<=0;
        if (!s_axi_aresetn) begin
            midstate<=0; tail<=0; target<=0; start_nonce<=0; tag<=0; selected<=0;
            hashes_hi_snapshot<=0;
        end
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
        if (s_axi_awvalid && s_axi_awready) begin
            awaddr<=s_axi_awaddr; awfull<=1; aw_wait<=0;
        end else if (awfull && !wfull && !s_axi_bvalid && !(s_axi_wvalid && s_axi_wready)) begin
            if (aw_wait==BEAT_BOUND-1) begin
                awfull<=0; wfull<=0; s_axi_bvalid<=1; s_axi_bresp<=2'b10;
            end else aw_wait<=aw_wait+1;
        end
        if (s_axi_wvalid && s_axi_wready) begin
            wdata<=s_axi_wdata; wstrb<=s_axi_wstrb; wfull<=1; w_wait<=0;
        end else if (wfull && !awfull && !s_axi_bvalid && !(s_axi_awvalid && s_axi_awready)) begin
            if (w_wait==BEAT_BOUND-1) begin
                awfull<=0; wfull<=0; s_axi_bvalid<=1; s_axi_bresp<=2'b10;
            end else w_wait<=w_wait+1;
        end
        if (awfull && wfull && !s_axi_bvalid) begin
            awfull<=0; wfull<=0; s_axi_bvalid<=1; s_axi_bresp<=0;
            if (s_axi_aresetn) case (awaddr)
                12'h008: if (wstrb[0]) begin
                    job_load<=wdata[0] && !wdata[1]; job_stop<=wdata[1];
                end
                12'h018: tag<=merge(tag,wdata,wstrb);
                12'h01c: start_nonce<=merge(start_nonce,wdata,wstrb);
                12'h028: begin
                    if (merge(selected,wdata,wstrb)<LANES) selected<=merge(selected,wdata,wstrb);
                    else s_axi_bresp<=2'b10;
                end
                12'h038: if (wstrb[0] && wdata[0]) pop[selected]<=1;
                default: begin
                    s_axi_bresp<=2'b10;
                    for (w=0;w<8;w=w+1) begin
                        if ({20'b0,awaddr}==32'h040+w*4) begin
                            midstate[255-w*32 -:32]<=merge(midstate[255-w*32 -:32],wdata,wstrb); s_axi_bresp<=0;
                        end
                        if ({20'b0,awaddr}==32'h080+w*4) begin
                            target[w*32 +:32]<=merge(target[w*32 +:32],wdata,wstrb); s_axi_bresp<=0;
                        end
                    end
                    for (w=0;w<3;w=w+1)
                        if ({20'b0,awaddr}==32'h060+w*4) begin
                            tail[95-w*32 -:32]<=merge(tail[95-w*32 -:32],wdata,wstrb); s_axi_bresp<=0;
                        end
                end
            endcase
        end
        if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid<=1; s_axi_rdata<=read_data; s_axi_rresp<=read_resp;
            if (s_axi_aresetn && s_axi_araddr==12'h020) hashes_hi_snapshot<=hashes[63:32];
        end else if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
            // ARREADY low with no response outstanding would withhold the read.
            s_axi_rvalid<=1; s_axi_rdata<=0; s_axi_rresp<=2'b10;
        end
    end
endmodule
