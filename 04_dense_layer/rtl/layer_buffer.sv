// =============================================================
// layer_buffer.sv
// Hidden Layer�쓽 requantize + ReLU 寃곌낵 ���옣�슜
// �떎�쓬 Dense Layer�뿉�뒗 �쟾泥� 諛곗뿴�쓣 �젣怨�
//
// [二쇱쓽]
// write 諛⑹떇�� Requantize/ReLU 援ы쁽 �솗�씤 �썑 蹂�寃� 媛��뒫
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
