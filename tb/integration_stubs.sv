`timescale 1ns/1ps
// SIMULATION ONLY. Do not compile alongside real modules or for synthesis.
// These models test packet-level wiring, not UART signaling or MLP arithmetic.
module uart_packet_rx #(
    parameter N_FEATURES=5, FEATURE_W=8, CLK_FREQ_HZ=100000000, BAUD_RATE=115200
) (
    input wire clk, rst_n, rx_i, ready_i,
    output reg [N_FEATURES*FEATURE_W-1:0] features_o,
    output reg valid_o, error_o
);
    initial begin features_o='0; valid_o=0; error_o=0; end
    always @(negedge rst_n) begin features_o='0; valid_o=0; error_o=0; end
    task automatic send_packet(input [N_FEATURES*FEATURE_W-1:0] value);
        @(negedge clk); features_o=value; valid_o=1;
        @(posedge clk);
        while (!ready_i) @(posedge clk);
        @(negedge clk); valid_o=0;
    endtask
    task automatic inject_error;
        @(negedge clk); error_o=1;
        @(negedge clk); error_o=0;
    endtask
endmodule

module feature_buffer #(parameter N_FEATURES=5, FEATURE_W=8) (
    input wire clk, rst_n, load_i,
    input wire [N_FEATURES*FEATURE_W-1:0] features_i,
    output reg [N_FEATURES*FEATURE_W-1:0] features_o
);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) features_o <= '0;
        else if (load_i) features_o <= features_i;
endmodule

module mlp_core #(parameter N_FEATURES=5, FEATURE_W=8, N_OUTPUTS=1, OUTPUT_W=16) (
    input wire clk, rst_n, mlp_start,
    input wire [N_FEATURES*FEATURE_W-1:0] features_i,
    output reg mlp_busy, mlp_done,
    output reg [N_OUTPUTS*OUTPUT_W-1:0] result_o
);
    integer remaining, starts, i;
    reg signed [OUTPUT_W-1:0] sum;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            remaining<=0; starts<=0; mlp_busy<=0; mlp_done<=0; result_o<='0;
        end else begin
            mlp_done<=0;
            if (mlp_start) begin
                if (mlp_busy) $fatal(1,"Duplicate start while busy");
                starts<=starts+1;
                sum='0;
                for (i=0;i<N_FEATURES;i=i+1)
                    sum=sum+$signed(features_i[i*FEATURE_W +: FEATURE_W]);
                result_o <= {{(N_OUTPUTS-1)*OUTPUT_W{1'b0}}, sum};
                remaining<=4; mlp_busy<=1;
            end else if (mlp_busy) begin
                if (remaining==1) begin mlp_busy<=0; mlp_done<=1; end
                remaining<=remaining-1;
            end
        end
    end
endmodule

module uart_packet_tx #(
    parameter N_OUTPUTS=1, OUTPUT_W=16, CLK_FREQ_HZ=100000000, BAUD_RATE=115200
) (
    input wire clk, rst_n, valid_i,
    input wire [N_OUTPUTS*OUTPUT_W-1:0] result_i,
    output wire ready_o, tx_o,
    output reg done_o
);
    reg allow_ready=0;
    integer remaining, sends;
    reg [N_OUTPUTS*OUTPUT_W-1:0] captured;
    assign ready_o = rst_n && allow_ready && (remaining==0);
    assign tx_o = 1'b1; // No serial emulation in this packet-level model.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin remaining<=0; sends<=0; captured<='0; done_o<=0; end
        else begin
            done_o<=0;
            if (valid_i && ready_o) begin
                captured<=result_i; sends<=sends+1; remaining<=6;
            end else if (remaining!=0) begin
                remaining<=remaining-1;
                if (remaining==1) done_o<=1;
            end
        end
    end
endmodule
