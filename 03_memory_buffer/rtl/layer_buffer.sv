// layer_buffer.sv
// Generic buffer for storing intermediate layer outputs.

module layer_buffer #(
    parameter int DATA_W = 8,
    parameter int DEPTH  = 16,

    parameter int ADDR_W =
        (DEPTH <= 1) ? 1 : $clog2(DEPTH)
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Dense / ReLU result write
    input  logic                    wr_en,
    input  logic [ADDR_W-1:0]       wr_addr,
    input  logic signed [DATA_W-1:0] wr_data,

    // Next layer read
    input  logic [ADDR_W-1:0]       rd_addr,
    output logic signed [DATA_W-1:0] rd_data
);

    logic signed [DATA_W-1:0] mem [0:DEPTH-1];

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= '0;
        end
        else if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    always_comb begin
        rd_data = mem[rd_addr];
    end

endmodule
