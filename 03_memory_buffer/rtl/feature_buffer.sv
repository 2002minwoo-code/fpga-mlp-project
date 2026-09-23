// =============================================================
// feature_buffer.sv
// UART 등에서 Feature를 하나씩 저장
// Dense Layer에는 전체 Feature 배열을 제공
// =============================================================
module feature_buffer #(
    parameter int FEATURE_W = 8,
    parameter int N_MAX     = 16,

    parameter int ADDR_W =
        (N_MAX > 1) ? $clog2(N_MAX) : 1
)(
    input  logic i_clk,
    input  logic i_rstn,

    // Write interface
    input  logic                     i_wr_en,
    input  logic [ADDR_W-1:0]        i_wr_addr,
    input  logic signed [FEATURE_W-1:0] i_wr_data,

    // Dense Layer로 전체 Feature 전달
    output logic signed [FEATURE_W-1:0]
        o_feature [0:N_MAX-1]
);

    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            for (int i = 0; i < N_MAX; i++) begin
                o_feature[i] <= '0;
            end
        end else if (i_wr_en) begin
            o_feature[i_wr_addr] <= i_wr_data;
        end
    end

endmodule
