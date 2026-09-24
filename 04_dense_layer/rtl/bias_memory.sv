// =============================================================
// bias_memory.sv
// ?븳 二쇱냼?뿉?꽌 N_MAC媛쒖쓽 bias瑜? packed ?삎?깭濡? 異쒕젰
// =============================================================
module bias_memory #(
    parameter int BIAS_W    = 32,
    parameter int N_NEURON  = 16,
    parameter int N_MAC     = 8,

    parameter int DATA_W = N_MAC * BIAS_W,
    //[수정 - dense layer 2 -> output layer 1/8 정수계산 올림 처리]
    parameter int DEPTH  = (N_NEURON + N_MAC - 1) / N_MAC,
    parameter int ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1,

    parameter INIT_FILE = "biases.mem"
)(
    input  logic              i_clk,
    input  logic              i_rstn,

    input  logic [ADDR_W-1:0] i_addr,
    output logic [DATA_W-1:0] o_data
);

    logic [DATA_W-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // synchronous read
    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn)
            o_data <= '0;
        else
            o_data <= mem[i_addr];
    end

endmodule
