// feature_buffer.sv
// Stores the input feature vector received from UART logic.
// UART 에서 Feature #0도착 -> mem[0]
// Feature #1 도착 -> mem[1] ... Feature 다 저장 완료 후 MLP start
// UART 담당 모듈에서 feature_wr_en, feature_wr_addr, feature_wr_data를 넘겨준다고 가정

module feature_buffer #(
    parameter int FEATURE_W  = 8,

    // [임시] 알고리즘팀 최종 Feature Selection 후 변경 가능
    parameter int N_FEATURES = 5,

    parameter int ADDR_W =
        (N_FEATURES <= 1) ? 1 : $clog2(N_FEATURES)
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // Write side: UART packet logic -> buffer
    input  logic                       wr_en,
    input  logic [ADDR_W-1:0]          wr_addr,
    input  logic signed [FEATURE_W-1:0] wr_data,

    // Read side: Dense Layer -> buffer
    input  logic [ADDR_W-1:0]          rd_addr,
    output logic signed [FEATURE_W-1:0] rd_data
);

    logic signed [FEATURE_W-1:0] mem [0:N_FEATURES-1];

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N_FEATURES; i = i + 1)
                mem[i] <= '0;
        end
        else if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // Small feature buffer:
    // combinational read is simple and convenient.
    always_comb begin
        rd_data = mem[rd_addr];
    end

endmodule
