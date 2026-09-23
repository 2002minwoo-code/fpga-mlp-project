// =============================================================
// mac_unit.sv
// =============================================================
module mac_unit #(
    parameter int FEATURE_W = 8,
    parameter int WEIGHT_W  = 8,
    parameter int BIAS_W    = 32,
    parameter int ACC_W     = 32
)(
    input  logic i_clk,
    input  logic i_rstn,

    input  logic i_clr, // 1일 때: Bias + (Feature * Weight) 초기화
    input  logic i_en,  // 1일 때: Accum + (Feature * Weight) 누적

    input  logic signed [BIAS_W-1:0]    i_b_data,
    input  logic signed [FEATURE_W-1:0] i_f_data,
    input  logic signed [WEIGHT_W-1:0]  i_w_data,

    output logic signed [ACC_W-1:0]     o_acc_data
);

    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_acc_data <= '0;
        end else if (i_clr) begin
            o_acc_data <= i_b_data + (i_f_data * i_w_data);
        end else if (i_en) begin
            o_acc_data <= o_acc_data + (i_f_data * i_w_data);
        end
    end

endmodule
