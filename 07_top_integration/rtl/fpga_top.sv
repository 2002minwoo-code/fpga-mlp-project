`timescale 1ns/1ps
`default_nettype none

// Proposed interfaces: see INTEGRATION.md before connecting team RTL.
// Packed vectors carry raw signed element bits; element 0 occupies the LSBs.
module fpga_top #(
    parameter integer N_FEATURES = 5,
    parameter integer FEATURE_W = 8,
    parameter integer N_OUTPUTS = 1,
    parameter integer OUTPUT_W = 16,
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE = 115_200
) (
    input  wire clk,
    input  wire reset_n,
    input  wire uart_rx_i,
    output wire uart_tx_o,
    output wire busy,
    output reg  done,
    output reg  error
);
    localparam [2:0] IDLE = 0, START_CORE = 1, WAIT_CORE = 2,
                     SEND_RESULT = 3, WAIT_TX = 4;
    reg [2:0] state;
    wire rst_n;
    wire [N_FEATURES*FEATURE_W-1:0] rx_features, features;
    wire rx_valid, rx_ready, rx_error;
    wire mlp_busy, mlp_done;
    wire [N_OUTPUTS*OUTPUT_W-1:0] mlp_result;
    reg  [N_OUTPUTS*OUTPUT_W-1:0] result_hold;
    wire tx_ready, tx_done;
    wire accept_packet = rx_valid && rx_ready;
    wire mlp_start = rst_n && (state == START_CORE) && !mlp_busy;
    wire tx_valid = rst_n && (state == SEND_RESULT);

    assign busy = rst_n && (state != IDLE);
    assign rx_ready = rst_n && (state == IDLE) && !mlp_busy;

    reset_sync u_reset (.clk(clk), .async_rst_n(reset_n), .rst_n(rst_n));

    // Packet RX owns serial synchronization, byte assembly and frame errors.
    uart_packet_rx #(
        .N_FEATURES(N_FEATURES), .FEATURE_W(FEATURE_W),
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)
    ) u_packet_rx (
        .clk(clk), .rst_n(rst_n), .rx_i(uart_rx_i),
        .features_o(rx_features), .valid_o(rx_valid),
        .ready_i(rx_ready), .error_o(rx_error)
    );

    // A complete vector is loaded atomically; it remains stable until next job.
    feature_buffer #(.N_FEATURES(N_FEATURES), .FEATURE_W(FEATURE_W))
    u_feature_buffer (
        .clk(clk), .rst_n(rst_n), .load_i(accept_packet),
        .features_i(rx_features), .features_o(features)
    );

    mlp_core #(
        .N_FEATURES(N_FEATURES), .FEATURE_W(FEATURE_W),
        .N_OUTPUTS(N_OUTPUTS), .OUTPUT_W(OUTPUT_W)
    ) u_mlp_core (
        .clk(clk), .rst_n(rst_n), .mlp_start(mlp_start),
        .features_i(features), .mlp_busy(mlp_busy),
        .mlp_done(mlp_done), .result_o(mlp_result)
    );

    uart_packet_tx #(
        .N_OUTPUTS(N_OUTPUTS), .OUTPUT_W(OUTPUT_W),
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)
    ) u_packet_tx (
        .clk(clk), .rst_n(rst_n), .result_i(result_hold),
        .valid_i(tx_valid), .ready_o(tx_ready),
        .done_o(tx_done), .tx_o(uart_tx_o)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            result_hold <= '0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;
            if (rx_error) error <= 1'b1; // Sticky until external reset.
            case (state)
                IDLE: if (accept_packet) state <= START_CORE;
                // Buffer load precedes start by one clock.
                START_CORE: if (!mlp_busy) state <= WAIT_CORE;
                WAIT_CORE: if (mlp_done) begin
                    result_hold <= mlp_result;
                    state <= SEND_RESULT;
                end
                // Hold data and valid until the transmitter accepts them.
                SEND_RESULT: if (tx_ready) begin
                    if (tx_done) begin
                        state <= IDLE;
                        done <= 1'b1;
                    end else state <= WAIT_TX;
                end
                WAIT_TX: if (tx_done) begin
                    state <= IDLE;
                    done <= 1'b1;
                end
                default: begin
                    state <= IDLE;
                    error <= 1'b1;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
