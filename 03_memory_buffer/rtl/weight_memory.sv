// =============================================================
// weight_memory.sv
// Dense Layer interface 기준
// 한 주소에서 N_MAC개의 weight를 packed 형태로 출력
// =============================================================
module weight_memory #(
    parameter int WEIGHT_W = 8,
    parameter int N_NEURON = 16,
    parameter int N_MAX    = 16,
    parameter int N_MAC    = 8,

    parameter int DATA_W = N_MAC * WEIGHT_W,
    parameter int DEPTH  = (N_NEURON / N_MAC) * N_MAX,
    parameter int ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1,

    parameter INIT_FILE = "weights.mem"
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
