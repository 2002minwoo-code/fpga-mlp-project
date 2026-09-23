// =============================================================
// layer_buffer.sv
// Hidden Layer의 requantize + ReLU 결과 저장용
// 다음 Dense Layer에는 전체 배열을 제공
//
// [주의]
// write 방식은 Requantize/ReLU 구현 확인 후 변경 가능
// =============================================================
module layer_buffer #(
    parameter int DATA_W = 8,
    parameter int DEPTH  = 16,

    parameter int ADDR_W =
        (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input  logic i_clk,
    input  logic i_rstn,

    input  logic                    i_wr_en,
    input  logic [ADDR_W-1:0]       i_wr_addr,
    input  logic signed [DATA_W-1:0] i_wr_data,

    output logic signed [DATA_W-1:0]
        o_data [0:DEPTH-1]
);

    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            for (int i = 0; i < DEPTH; i++) begin
                o_data[i] <= '0;
            end
        end else if (i_wr_en) begin
            o_data[i_wr_addr] <= i_wr_data;
        end
    end

endmodule
