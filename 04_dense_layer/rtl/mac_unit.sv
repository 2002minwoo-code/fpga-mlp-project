`timescale 1ns / 1ps

module mac_unit #(
    parameter int FEATURE_W = 8,
    parameter int WEIGHT_W  = 8,
    parameter int BIAS_W    = 32,
    parameter int ACC_W     = 32
)(
    input  logic i_clk,
    input  logic i_rstn,
    input  logic i_clr,
    input  logic i_en,
    input  logic signed [FEATURE_W-1:0] i_feature,
    input  logic signed [WEIGHT_W-1:0]  i_weight,
    input  logic signed [BIAS_W-1:0]    i_bias,
    output logic signed [ACC_W-1:0]     o_acc
);

    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_acc <= '0;
        end else if (i_clr) begin
            o_acc <= $signed(i_bias);
        end else if (i_en) begin
            o_acc <= o_acc + ($signed(i_feature) * $signed(i_weight));
        end
    end

endmodule
