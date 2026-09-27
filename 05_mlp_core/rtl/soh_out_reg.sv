`timescale 1ns / 1ps

// =============================================================
// soh_out_reg.sv
// MLP Layer 3의 최종 32-bit 연산 결과를 컨트롤러 인에이블 펄스에
// 맞춰 저장하고 UART 송신 컨버터로 안정적으로 유지/출력하는 모듈
// =============================================================
module soh_out_reg #(
    parameter int DATA_W = 32
)(
    input  logic                     i_clk,
    input  logic                     i_rstn,

    // MLP Controller Interface
    input  logic                     i_reg_en,    // mlp_controller의 o_soh_reg_en 연결

    // MLP Core Interface
    input  logic signed [DATA_W-1:0] i_data,      // mlp_core의 o_mlp_data 연결

    // UART Converter Interface
    output logic signed [DATA_W-1:0] o_soh_data   // UART 변환기로 나가는 최종 SOH 데이터
);

    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_soh_data <= '0;
        end else if (i_reg_en) begin
            o_soh_data <= i_data;
        end
    end

endmodule
