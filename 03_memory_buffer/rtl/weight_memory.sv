// weight_memory.sv
// Stores quantized signed weights for the whole MLP.
// 현재 5-> 16-> 8-> 1 이면 weight 개수는 총 216개
// N_FEATURES가 바뀌면 DEPTH도 자동으로 바뀜

module weight_memory #(
    parameter int WEIGHT_W = 8,

    // [임시] 구조
    parameter int N_FEATURES = 5,
    parameter int N_HIDDEN1  = 16,
    parameter int N_HIDDEN2  = 8,
    parameter int N_OUTPUTS  = 1,

    parameter int DEPTH =
        (N_FEATURES * N_HIDDEN1) +
        (N_HIDDEN1  * N_HIDDEN2) +
        (N_HIDDEN2  * N_OUTPUTS),

    parameter int ADDR_W =
        (DEPTH <= 1) ? 1 : $clog2(DEPTH),

    parameter string INIT_FILE = "weights.mem"
)(
    input  logic                     clk,
    input  logic                     rd_en,
    input  logic [ADDR_W-1:0]        rd_addr,

    output logic signed [WEIGHT_W-1:0] rd_data
);

    logic signed [WEIGHT_W-1:0] mem [0:DEPTH-1];

    // Simulation / FPGA initialization
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // Synchronous read
    always_ff @(posedge clk) begin
        if (rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
