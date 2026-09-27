`timescale 1ns / 1ps

// ============================================================================
// Module: mlp_core
// Description:
//   - MLP Data Path 구현 모듈 (구조 2: Shared Layer Buffer 구조)
//   - Feature Buffer -> Dense1 -> ReLU/Requant -> Shared Buffer -> Dense2 
//     -> ReLU/Requant -> Shared Buffer -> Dense3 -> o_mlp_data
// ============================================================================

(* DONT_TOUCH = "yes" *)
module mlp_core #(
    parameter int FEATURE_W      = 8,
    parameter int WEIGHT_W       = 8,
    parameter int BIAS_W         = 32,
    parameter int ACC_W          = 32,
    parameter int N_MAC          = 8,

    parameter int N_INPUTS       = 5,
    parameter int N_NEURONS_L1   = 16,
    parameter int N_NEURONS_L2   = 8,
    parameter int N_NEURONS_L3   = 1,
    parameter int N_MAX          = 16,

    parameter int FEAT_ADDR_W    = (N_INPUTS > 1) ? $clog2(N_INPUTS) : 1,
    parameter int BUF_ADDR_W     = 4,

    parameter int IN_FRAC        = 8,
    parameter int OUT_FRAC       = 4,

    parameter string L1_WMEM_FILE = "wmem_l1.mem",
    parameter string L1_BMEM_FILE = "bmem_l1.mem",
    parameter string L2_WMEM_FILE = "wmem_l2.mem",
    parameter string L2_BMEM_FILE = "bmem_l2.mem",
    parameter string L3_WMEM_FILE = "wmem_l3.mem",
    parameter string L3_BMEM_FILE = "bmem_l3.mem"
)(
    input  logic                                  i_clk,
    input  logic                                  i_rstn,

    // UART Feature 입력 인터페이스
    input  logic                                  i_feat_wr_en,
    input  logic [FEAT_ADDR_W-1:0]                i_feat_wr_addr,
    input  logic signed [FEATURE_W-1:0]           i_feat_wr_data,

    // Controller 제어 인터페이스
    input  logic [1:0]                            i_layer_sel,
    input  logic                                  i_dense_start,
    output logic                                  o_dense_done,
    input  logic                                  i_buf_wr_en,
    input  logic [BUF_ADDR_W-1:0]                 i_buf_wr_addr,

    // 최종 결과 출력 인터페이스
    output logic signed [ACC_W-1:0]               o_mlp_data
);

    // =========================================================================
    // 1. 메모리 어드레스 비트폭 및 데이터 버스 파라미터 계산
    // =========================================================================
    localparam int WMEM_DATA_W = N_MAC * WEIGHT_W; // 8 * 8 = 64-bit
    localparam int BMEM_DATA_W = N_MAC * BIAS_W;   // 8 * 32 = 256-bit

    // L1 Address Width
    localparam int L1_NUM_GROUPS = (N_NEURONS_L1 + N_MAC - 1) / N_MAC; // 2
    localparam int L1_WMEM_DEPTH = L1_NUM_GROUPS * N_MAX;              // 32
    localparam int L1_WMEM_ADDR_W = (L1_WMEM_DEPTH > 1) ? $clog2(L1_WMEM_DEPTH) : 1; // 5-bit
    localparam int L1_BMEM_ADDR_W = (L1_NUM_GROUPS > 1) ? $clog2(L1_NUM_GROUPS) : 1; // 1-bit

    // L2 Address Width
    localparam int L2_NUM_GROUPS = (N_NEURONS_L2 + N_MAC - 1) / N_MAC; // 1
    localparam int L2_WMEM_DEPTH = L2_NUM_GROUPS * N_MAX;              // 16
    localparam int L2_WMEM_ADDR_W = (L2_WMEM_DEPTH > 1) ? $clog2(L2_WMEM_DEPTH) : 1; // 4-bit
    localparam int L2_BMEM_ADDR_W = (L2_NUM_GROUPS > 1) ? $clog2(L2_NUM_GROUPS) : 1; // 1-bit

    // L3 Address Width
    localparam int L3_NUM_GROUPS = (N_NEURONS_L3 + N_MAC - 1) / N_MAC; // 1
    localparam int L3_WMEM_DEPTH = L3_NUM_GROUPS * N_MAX;              // 16
    localparam int L3_WMEM_ADDR_W = (L3_WMEM_DEPTH > 1) ? $clog2(L3_WMEM_DEPTH) : 1; // 4-bit
    localparam int L3_BMEM_ADDR_W = (L3_NUM_GROUPS > 1) ? $clog2(L3_NUM_GROUPS) : 1; // 1-bit

    // =========================================================================
    // 2. 내부 인터커넥트 와이어 선언
    // =========================================================================

    // Dense Layer 핸드셰이크 분기/멀티플렉싱
    logic l1_start, l2_start, l3_start;
    logic l1_done,  l2_done,  l3_done;
    logic l1_busy,  l2_busy,  l3_busy;

    // Feature Buffer 출력
    logic signed [FEATURE_W-1:0] feat_buf_out [0:N_MAX-1];

    // Shared Layer Buffer 1 출력
    logic signed [FEATURE_W-1:0] shared_buf_out [0:N_MAX-1];

    // Layer 1 중간 신호
    logic [L1_WMEM_ADDR_W-1:0]   l1_wmem_addr;
    logic [WMEM_DATA_W-1:0]      l1_wmem_data;
    logic [L1_BMEM_ADDR_W-1:0]   l1_bmem_addr;
    logic [BMEM_DATA_W-1:0]      l1_bmem_data;
    logic signed [ACC_W-1:0]     l1_result       [0:N_NEURONS_L1-1];
    logic signed [ACC_W-1:0]     l1_relu_out     [0:N_NEURONS_L1-1];
    logic signed [FEATURE_W-1:0] l1_requant_out  [0:N_NEURONS_L1-1];

    // Layer 2 중간 신호
    logic [L2_WMEM_ADDR_W-1:0]   l2_wmem_addr;
    logic [WMEM_DATA_W-1:0]      l2_wmem_data;
    logic [L2_BMEM_ADDR_W-1:0]   l2_bmem_addr;
    logic [BMEM_DATA_W-1:0]      l2_bmem_data;
    logic signed [ACC_W-1:0]     l2_result       [0:N_NEURONS_L2-1];
    logic signed [ACC_W-1:0]     l2_relu_out     [0:N_NEURONS_L2-1];
    logic signed [FEATURE_W-1:0] l2_requant_out  [0:N_NEURONS_L2-1];

    // Layer 3 중간 신호
    logic [L3_WMEM_ADDR_W-1:0]   l3_wmem_addr;
    logic [WMEM_DATA_W-1:0]      l3_wmem_data;
    logic [L3_BMEM_ADDR_W-1:0]   l3_bmem_addr;
    logic [BMEM_DATA_W-1:0]      l3_bmem_data;
    logic signed [ACC_W-1:0]     l3_result       [0:N_NEURONS_L3-1];

    // Shared Buffer 2:1 Write Data MUX 신호
    logic signed [FEATURE_W-1:0] shared_buf_wr_data;

    // =========================================================================
    // 3. 제어 신호 디코딩 및 멀티플렉싱
    // =========================================================================

    // Dense Start 신호 분기 (i_layer_sel 기반)
    assign l1_start = (i_layer_sel == 2'd0) ? i_dense_start : 1'b0;
    assign l2_start = (i_layer_sel == 2'd1) ? i_dense_start : 1'b0;
    assign l3_start = (i_layer_sel == 2'd2) ? i_dense_start : 1'b0;

    // Dense Done 신호 선택 (현재 실행 중인 레이어의 Done을 Controller로 전달)
    always_comb begin
        case (i_layer_sel)
            2'd0:    o_dense_done = l1_done;
            2'd1:    o_dense_done = l2_done;
            2'd2:    o_dense_done = l3_done;
            default: o_dense_done = 1'b0;
        endcase
    end

    // Shared Layer Buffer 2:1 쓰기 데이터 MUX
    // (L1 실행 후 쓰기 시 L1 Requantize 결과 선택, L2 실행 후 쓰기 시 L2 Requantize 결과 선택)
    always_comb begin
        if (i_layer_sel == 2'd0) begin
            shared_buf_wr_data = l1_requant_out[i_buf_wr_addr];
        end else begin
            shared_buf_wr_data = l2_requant_out[i_buf_wr_addr[2:0]];
        end
    end

    // 최종 결과 출력 연결 (Dense Layer 3 결과의 0번 뉴런)
    assign o_mlp_data = l3_result[0];

    // =========================================================================
    // 4. Feature Buffer (UART 입력값 저장용)
    // =========================================================================
    feature_buffer #(
        .FEATURE_W (FEATURE_W),
        .N_MAX     (N_MAX)
    ) u_feature_buffer (
        .i_clk     (i_clk),
        .i_rstn    (i_rstn),
        .i_wr_en   (i_feat_wr_en),
        .i_wr_addr ({{(4-FEAT_ADDR_W){1'b0}}, i_feat_wr_addr}), // 4비트 주소 확장
        .i_wr_data (i_feat_wr_data),
        .o_feature (feat_buf_out)
    );

    // =========================================================================
    // 5. Shared Layer Buffer 1 (L1/L2 결과 공유 버퍼, 깊이 16)
    // =========================================================================
    layer_buffer #(
        .DATA_W (FEATURE_W),
        .DEPTH  (N_MAX) // 16
    ) u_shared_layer_buffer1 (
        .i_clk     (i_clk),
        .i_rstn    (i_rstn),
        .i_wr_en   (i_buf_wr_en),
        .i_wr_addr (i_buf_wr_addr),
        .i_wr_data (shared_buf_wr_data),
        .o_data    (shared_buf_out)
    );

    // =========================================================================
    // 6. LAYER 1 하드웨어 인스턴스 (Input 5 -> L1 16)
    // =========================================================================
    weight_memory #(
        .WEIGHT_W  (WEIGHT_W),
        .N_NEURON  (N_NEURONS_L1),
        .N_MAX     (N_MAX),
        .N_MAC     (N_MAC),
        .INIT_FILE (L1_WMEM_FILE)
    ) u_wmem_l1 (
        .i_clk  (i_clk),
        .i_rstn (i_rstn),
        .i_addr (l1_wmem_addr),
        .o_data (l1_wmem_data)
    );

    bias_memory #(
        .BIAS_W    (BIAS_W),
        .N_NEURON  (N_NEURONS_L1),
        .N_MAC     (N_MAC),
        .INIT_FILE (L1_BMEM_FILE)
    ) u_bmem_l1 (
        .i_clk  (i_clk),
        .i_rstn (i_rstn),
        .i_addr (l1_bmem_addr),
        .o_data (l1_bmem_data)
    );

    dense_layer #(
        .FEATURE_W (FEATURE_W),
        .WEIGHT_W  (WEIGHT_W),
        .BIAS_W    (BIAS_W),
        .N_NEURON  (N_NEURONS_L1),
        .N_MAX     (N_MAX),
        .ACC_W     (ACC_W),
        .N_MAC     (N_MAC)
    ) u_dense_l1 (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_start       (l1_start),
        .i_num_neurons (N_NEURONS_L1),
        .i_num_inputs  (N_INPUTS),
        .i_feature     (feat_buf_out), // Feature Buffer 직결
        .o_wmem_addr   (l1_wmem_addr),
        .i_wmem_data   (l1_wmem_data),
        .o_bmem_addr   (l1_bmem_addr),
        .i_bmem_data   (l1_bmem_data),
        .o_result      (l1_result),
        .o_busy        (l1_busy),
        .o_done        (l1_done)
    );

    relu_layer #(
        .IN_W     (ACC_W),
        .N_NEURON (N_NEURONS_L1)
    ) u_relu_l1 (
        .in_data  (l1_result),
        .out_data (l1_relu_out)
    );

    requantize_layer #(
        .IN_W     (ACC_W),
        .IN_FRAC  (IN_FRAC),
        .OUT_W    (FEATURE_W),
        .OUT_FRAC (OUT_FRAC),
        .N_NEURON (N_NEURONS_L1)
    ) u_requant_l1 (
        .in_data  (l1_relu_out),
        .out_data (l1_requant_out)
    );

    // =========================================================================
    // 7. LAYER 2 하드웨어 인스턴스 (L1 16 -> L2 8)
    // =========================================================================
    weight_memory #(
        .WEIGHT_W  (WEIGHT_W),
        .N_NEURON  (N_NEURONS_L2),
        .N_MAX     (N_MAX),
        .N_MAC     (N_MAC),
        .INIT_FILE (L2_WMEM_FILE)
    ) u_wmem_l2 (
        .i_clk  (i_clk),
        .i_rstn (i_rstn),
        .i_addr (l2_wmem_addr),
        .o_data (l2_wmem_data)
    );

    bias_memory #(
        .BIAS_W    (BIAS_W),
        .N_NEURON  (N_NEURONS_L2),
        .N_MAC     (N_MAC),
        .INIT_FILE (L2_BMEM_FILE)
    ) u_bmem_l2 (
        .i_clk  (i_clk),
        .i_rstn (i_rstn),
        .i_addr (l2_bmem_addr),
        .o_data (l2_bmem_data)
    );

    dense_layer #(
        .FEATURE_W (FEATURE_W),
        .WEIGHT_W  (WEIGHT_W),
        .BIAS_W    (BIAS_W),
        .N_NEURON  (N_NEURONS_L2),
        .N_MAX     (N_MAX),
        .ACC_W     (ACC_W),
        .N_MAC     (N_MAC)
    ) u_dense_l2 (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_start       (l2_start),
        .i_num_neurons (N_NEURONS_L2),
        .i_num_inputs  (N_NEURONS_L1),
        .i_feature     (shared_buf_out), // Shared Buffer 전체 16개 참조
        .o_wmem_addr   (l2_wmem_addr),
        .i_wmem_data   (l2_wmem_data),
        .o_bmem_addr   (l2_bmem_addr),
        .i_bmem_data   (l2_bmem_data),
        .o_result      (l2_result),
        .o_busy        (l2_busy),
        .o_done        (l2_done)
    );

    relu_layer #(
        .IN_W     (ACC_W),
        .N_NEURON (N_NEURONS_L2)
    ) u_relu_l2 (
        .in_data  (l2_result),
        .out_data (l2_relu_out)
    );

    requantize_layer #(
        .IN_W     (ACC_W),
        .IN_FRAC  (IN_FRAC),
        .OUT_W    (FEATURE_W),
        .OUT_FRAC (OUT_FRAC),
        .N_NEURON (N_NEURONS_L2)
    ) u_requant_l2 (
        .in_data  (l2_relu_out),
        .out_data (l2_requant_out)
    );

    // =========================================================================
    // 8. LAYER 3 하드웨어 인스턴스 (L2 8 -> Output 1)
    // =========================================================================
    weight_memory #(
        .WEIGHT_W  (WEIGHT_W),
        .N_NEURON  (N_NEURONS_L3),
        .N_MAX     (N_MAX),
        .N_MAC     (N_MAC),
        .INIT_FILE (L3_WMEM_FILE)
    ) u_wmem_l3 (
        .i_clk  (i_clk),
        .i_rstn (i_rstn),
        .i_addr (l3_wmem_addr),
        .o_data (l3_wmem_data)
    );

    bias_memory #(
        .BIAS_W    (BIAS_W),
        .N_NEURON  (N_NEURONS_L3),
        .N_MAC     (N_MAC),
        .INIT_FILE (L3_BMEM_FILE)
    ) u_bmem_l3 (
        .i_clk  (i_clk),
        .i_rstn (i_rstn),
        .i_addr (l3_bmem_addr),
        .o_data (l3_bmem_data)
    );

    dense_layer #(
        .FEATURE_W (FEATURE_W),
        .WEIGHT_W  (WEIGHT_W),
        .BIAS_W    (BIAS_W),
        .N_NEURON  (N_NEURONS_L3),
        .N_MAX     (N_MAX),
        .ACC_W     (ACC_W),
        .N_MAC     (N_MAC)
    ) u_dense_l3 (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_start       (l3_start),
        .i_num_neurons (N_NEURONS_L3),
        .i_num_inputs  (N_NEURONS_L2),
        .i_feature     (shared_buf_out), // Shared Buffer 앞부분 8개만 참조
        .o_wmem_addr   (l3_wmem_addr),
        .i_wmem_data   (l3_wmem_data),
        .o_bmem_addr   (l3_bmem_addr),
        .i_bmem_data   (l3_bmem_data),
        .o_result      (l3_result),
        .o_busy        (l3_busy),
        .o_done        (l3_done)
    );

endmodule
