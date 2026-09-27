`timescale 1ns / 1ps

// ============================================================================
// Module: mlp_top
// Description:
//   - MLP Controller, MLP Core, SOH Result Register를 통합하는 최상위 모듈
//   - Core 내부 구조(개별 버퍼 vs 공유 버퍼)와 무관하게 완전히 동일한 인터페이스 유지
// ============================================================================

module mlp_top #(
    // 아키텍처 공통 파라미터
    parameter int FEATURE_W      = 8,   // 입력 피처 비트폭 (int8)
    parameter int WEIGHT_W       = 8,   // 가중치 비트폭 (int8)
    parameter int BIAS_W         = 32,  // 편향 비트폭 (int32)
    parameter int ACC_W          = 32,  // MAC 누적기 비트폭 (int32)
    parameter int N_MAC          = 8,   // Dense Layer 내부 병렬 MAC 수

    // 레이어별 뉴런 규격
    parameter int N_INPUTS       = 5,   // 입력 피처 개수
    parameter int N_NEURONS_L1   = 16,  // Layer 1 출력 뉴런 수
    parameter int N_NEURONS_L2   = 8,   // Layer 2 출력 뉴런 수
    parameter int N_NEURONS_L3   = 1,   // Layer 3 (Output) 출력 뉴런 수
    parameter int N_MAX          = 16,  // 최대 지원 피처 수

    // 버퍼 주소 비트폭
    parameter int FEAT_ADDR_W    = (N_INPUTS > 1) ? $clog2(N_INPUTS) : 1, // 3-bit (5개 입력)
    parameter int BUF_ADDR_W     = 4,                                    // 4-bit (16개 주소)

    // 재양자화(Requantize) 고정소수점 파라미터
    parameter int IN_FRAC        = 8,   // Layer 1/2 누적기 소수부
    parameter int OUT_FRAC       = 4,   // Requantize 후 출력 소수부

    // 메모리 초기화 파일 경로 (.mem)
    parameter string L1_WMEM_FILE = "wmem_l1.mem",
    parameter string L1_BMEM_FILE = "bmem_l1.mem",
    parameter string L2_WMEM_FILE = "wmem_l2.mem",
    parameter string L2_BMEM_FILE = "bmem_l2.mem",
    parameter string L3_WMEM_FILE = "wmem_l3.mem",
    parameter string L3_BMEM_FILE = "bmem_l3.mem"
)(
    input  logic                                  i_clk,
    input  logic                                  i_rstn,

    // -------------------------------------------------------------
    // 1. TOP Controller Interface (추론 제어 및 상태 보고)
    // -------------------------------------------------------------
    input  logic                                  i_mlp_start,     // 추론 시작 펄스
    output logic                                  o_mlp_busy,      // 추론 진행 중 표시
    output logic                                  o_mlp_done,      // 추론 완료 1클럭 펄스

    // -------------------------------------------------------------
    // 2. UART-to-MLP Data Converter Interface (Feature 버퍼 입력)
    // -------------------------------------------------------------
    input  logic                                  i_feat_wr_en,    // Feature 쓰기 인에이블
    input  logic [FEAT_ADDR_W-1:0]                i_feat_wr_addr,  // Feature 쓰기 주소 (0~4)
    input  logic signed [FEATURE_W-1:0]           i_feat_wr_data,  // Feature 입력 데이터 (8-bit)

    // -------------------------------------------------------------
    // 3. MLP-to-UART Data Converter Interface (최종 SOH 결과 출력)
    // -------------------------------------------------------------
    output logic signed [ACC_W-1:0]               o_soh_data       // 안정적으로 유지되는 최종 SOH 32-bit 값
);

    // =========================================================================
    // 내부 인터커넥트 신호 (Internal Interconnects)
    // =========================================================================

    // Controller <-> Core 신호
    logic [1:0]              layer_sel;       // 2'd0: L1, 2'd1: L2, 2'd2: L3
    logic                    dense_start;     // Dense Layer 구동용 1클럭 펄스
    logic                    dense_done;      // Core의 각 Dense Layer 완료 신호
    logic                    buf_wr_en;       // Core 내부 버퍼 쓰기 인에이블
    logic [BUF_ADDR_W-1:0]   buf_wr_addr;     // Core 내부 버퍼 쓰기 주소

    // Controller -> SOH Register 제어 신호
    logic                    soh_reg_en;      // SOH Register 래치 1클럭 펄스

    // Core -> SOH Register 데이터 신호
    logic signed [ACC_W-1:0] core_mlp_data;   // L3 연산 결과 (32-bit SOH raw data)

    // =========================================================================
    // 1. MLP Controller 인스턴스
    // =========================================================================
    mlp_controller #(
        .N_NEURONS_L1 (N_NEURONS_L1),
        .N_NEURONS_L2 (N_NEURONS_L2),
        .BUF_ADDR_W   (BUF_ADDR_W)
    ) u_mlp_controller (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),

        // TOP Controller
        .i_mlp_start   (i_mlp_start),
        .o_mlp_busy    (o_mlp_busy),
        .o_mlp_done    (o_mlp_done),

        // Core Control
        .o_layer_sel   (layer_sel),
        .o_dense_start (dense_start),
        .i_dense_done  (dense_done),
        .o_buf_wr_en   (buf_wr_en),
        .o_buf_wr_addr (buf_wr_addr),

        // SOH Register Control
        .o_soh_reg_en  (soh_reg_en)
    );

    // =========================================================================
    // 2. MLP Core 인스턴스
    //    (구조 1: Buffer 3개 구조 또는 구조 2: Shared Buffer 구조와 100% 핀 매핑 호환)
    // =========================================================================
    (* DONT_TOUCH = "yes" *)
    mlp_core #(
        .FEATURE_W     (FEATURE_W),
        .WEIGHT_W      (WEIGHT_W),
        .BIAS_W        (BIAS_W),
        .ACC_W         (ACC_W),
        .N_MAC         (N_MAC),
        .N_INPUTS      (N_INPUTS),
        .N_NEURONS_L1  (N_NEURONS_L1),
        .N_NEURONS_L2  (N_NEURONS_L2),
        .N_NEURONS_L3  (N_NEURONS_L3),
        .N_MAX         (N_MAX),
        .FEAT_ADDR_W   (FEAT_ADDR_W),
        .BUF_ADDR_W    (BUF_ADDR_W),
        .IN_FRAC       (IN_FRAC),
        .OUT_FRAC      (OUT_FRAC),
        .L1_WMEM_FILE  (L1_WMEM_FILE),
        .L1_BMEM_FILE  (L1_BMEM_FILE),
        .L2_WMEM_FILE  (L2_WMEM_FILE),
        .L2_BMEM_FILE  (L2_BMEM_FILE),
        .L3_WMEM_FILE  (L3_WMEM_FILE),
        .L3_BMEM_FILE  (L3_BMEM_FILE)
    ) u_mlp_core (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),

        // UART Feature 입력 인터페이스
        .i_feat_wr_en  (i_feat_wr_en),
        .i_feat_wr_addr(i_feat_wr_addr),
        .i_feat_wr_data(i_feat_wr_data),

        // Controller 제어 인터페이스
        .i_layer_sel   (layer_sel),
        .i_dense_start (dense_start),
        .o_dense_done  (dense_done),
        .i_buf_wr_en   (buf_wr_en),
        .i_buf_wr_addr (buf_wr_addr),

        // 최종 연산 결과 출력
        .o_mlp_data    (core_mlp_data)
    );

    // =========================================================================
    // 3. SOH Result Register 인스턴스
    // =========================================================================
    soh_out_reg #(
        .DATA_W        (ACC_W)
    ) u_soh_out_reg (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),

        .i_reg_en      (soh_reg_en),    // mlp_controller의 o_soh_reg_en 연결
        .i_data        (core_mlp_data), // mlp_core의 o_mlp_data 연결
        .o_soh_data    (o_soh_data)     // UART 송신부로 출력되는 최종 32비트 결과
    );

endmodule
