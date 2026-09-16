// bias_memory.sv
// Stores quantized signed biases for the whole MLP.
// 현재 구조면 Dense1 bias = 16 
//Dense2 bias = 8
//Dense3 bias = 1 총 25개


module bias_memory #(
    parameter int BIAS_W = 32,

    parameter int N_HIDDEN1 = 16,
    parameter int N_HIDDEN2 = 8,
    parameter int N_OUTPUTS = 1,

    parameter int DEPTH =
        N_HIDDEN1 +
        N_HIDDEN2 +
        N_OUTPUTS,

    parameter int ADDR_W =
        (DEPTH <= 1) ? 1 : $clog2(DEPTH),

    parameter string INIT_FILE = "biases.mem"
)(
    input  logic                   clk,
    input  logic                   rd_en,
    input  logic [ADDR_W-1:0]      rd_addr,

    output logic signed [BIAS_W-1:0] rd_data
);

    logic signed [BIAS_W-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge clk) begin
        if (rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
