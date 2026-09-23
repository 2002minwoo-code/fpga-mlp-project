// =============================================================
// mac_unit.sv 
// =============================================================
module mac_unit #(
    parameter int FEATURE_W = 8,
    parameter int WEIGHT_W  = 8,
    parameter int BIAS_W    = 32,
    parameter int ACC_W     = 32
)(
    input  logic clk,
    input  logic rst_n,

    input  logic clr, // 1일 때: Bias 값 및 첫 곱셈 결과로 초기화
    input  logic en,  // 1일 때: 기존 누적값 + (f_in * w_in) 연산

    input  logic signed [BIAS_W-1:0]    b_in, // BRAM에서 읽어온 Bias
    input  logic signed [FEATURE_W-1:0] f_in, // 입력 Feature
    input  logic signed [WEIGHT_W-1:0]  w_in, // BRAM에서 읽어온 Weight

    output logic signed [ACC_W-1:0]     acc_out // 연산 결과
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else if (clr) begin
            // 첫 번째 피처 연산: Bias + (Feature[0] * Weight[0])
            acc_out <= b_in + (f_in * w_in);
        end else if (en) begin
            // 이후 피처 연산: 기존 값 + (Feature[i] * Weight[i])
            acc_out <= acc_out + (f_in * w_in);
        end
    end

endmodule
