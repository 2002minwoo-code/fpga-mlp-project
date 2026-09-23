`timescale 1ns/1ps
`default_nettype none

module fpga_top #(
    parameter integer N_FEATURES  = 5,
    parameter integer FEATURE_W   = 8,
    parameter integer N_OUTPUTS   = 1,
    parameter integer OUTPUT_W    = 16,
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE   = 115_200
)(
    input  wire clk,
    input  wire reset_n,

    input  wire uart_rx_i,
    output wire uart_tx_o,

    output wire busy,
    output reg  done,
    output reg  error
);

    // N_FEATURES와 데이터 비트폭은 1 이상이어야 한다.
    localparam integer FEATURE_ADDR_W =
        (N_FEATURES <= 1) ? 1 : $clog2(N_FEATURES);

    localparam integer FEATURE_VEC_W =
        N_FEATURES * FEATURE_W;

    localparam integer RESULT_VEC_W =
        N_OUTPUTS * OUTPUT_W;

    // 전체 실행 상태
    localparam [2:0]
        IDLE           = 3'd0,
        STORE_FEATURES = 3'd1,
        LOAD_FEATURES  = 3'd2,
        START_CORE     = 3'd3,
        WAIT_CORE      = 3'd4,
        SEND_RESULT    = 3'd5,
        WAIT_TX        = 3'd6;

    reg [2:0] state;

    // ---------------------------------------------------------
    // Reset
    // ---------------------------------------------------------
    wire rst_n;

    reset_sync u_reset (
        .clk        (clk),
        .async_rst_n(reset_n),
        .rst_n      (rst_n)
    );

    // ---------------------------------------------------------
    // UART Packet RX
    //
    // 제안 규약:
    // - 정상 패킷 전체가 준비되면 rx_valid = 1
    // - rx_valid && rx_ready인 상승 에지에 패킷 전달
    // - 수락 전까지 rx_features를 유지
    // - 오류 패킷은 정상 valid로 전달하지 않음
    // - Feature 0은 벡터의 하위 FEATURE_W 비트
    // ---------------------------------------------------------
    wire [FEATURE_VEC_W-1:0] rx_features;
    wire rx_valid;
    wire rx_ready;
    wire rx_error;

    // 수락한 패킷을 별도 저장한다.
    // 이후 UART 출력이 바뀌어도 Buffer 쓰기에 영향이 없다.
    reg [FEATURE_VEC_W-1:0] rx_features_hold;

    // ---------------------------------------------------------
    // Feature Buffer
    // ---------------------------------------------------------
    reg [FEATURE_ADDR_W-1:0] feature_idx;

    wire feature_wr_en;
    wire [FEATURE_ADDR_W-1:0] feature_wr_addr;
    wire signed [FEATURE_W-1:0] feature_wr_data;

    wire [FEATURE_ADDR_W-1:0] feature_rd_addr;
    wire signed [FEATURE_W-1:0] feature_rd_data;

    // Buffer에서 읽은 값을 MLP 전달용 벡터로 구성한다.
    reg [FEATURE_VEC_W-1:0] features;

    // ---------------------------------------------------------
    // MLP Core
    //
    // 기존 제안 규약 유지:
    // features_i는 packed vector이다.
    // 실제 Dense의 배열 입력으로 변환하는 작업은
    // mlp_core 내부에서 수행해야 한다.
    // ---------------------------------------------------------
    wire mlp_start;
    wire mlp_busy;
    wire mlp_done;
    wire [RESULT_VEC_W-1:0] mlp_result;

    reg [RESULT_VEC_W-1:0] result_hold;

    // ---------------------------------------------------------
    // UART Packet TX
    // ---------------------------------------------------------
    wire tx_valid;
    wire tx_ready;
    wire tx_done;

    wire accept_packet;

    // ---------------------------------------------------------
    // 상태에 따른 제어 신호
    // ---------------------------------------------------------
    assign busy =
        rst_n && (state != IDLE);

    assign rx_ready =
        rst_n &&
        (state == IDLE) &&
        !mlp_busy &&
        !rx_error;

    assign accept_packet =
        rx_valid && rx_ready;

    assign mlp_start =
        rst_n &&
        (state == START_CORE) &&
        !mlp_busy;

    assign tx_valid =
        rst_n && (state == SEND_RESULT);

    // STORE_FEATURES에서만 Buffer를 쓴다.
    assign feature_wr_en =
        rst_n && (state == STORE_FEATURES);

    assign feature_wr_addr = feature_idx;

    // idx번째 Feature를 입력 벡터에서 추출한다.
    assign feature_wr_data =
        $signed(
            rx_features_hold[
                feature_idx * FEATURE_W +: FEATURE_W
            ]
        );

    assign feature_rd_addr = feature_idx;

    // ---------------------------------------------------------
    // 모듈 연결
    // ---------------------------------------------------------
    uart_packet_rx #(
        .N_FEATURES (N_FEATURES),
        .FEATURE_W  (FEATURE_W),
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_packet_rx (
        .clk       (clk),
        .rst_n     (rst_n),
        .rx_i      (uart_rx_i),

        .features_o(rx_features),
        .valid_o   (rx_valid),
        .ready_i   (rx_ready),
        .error_o   (rx_error)
    );

    // 실제 03_memory_buffer의 포트에 맞춘 연결
    feature_buffer #(
        .FEATURE_W (FEATURE_W),
        .N_FEATURES(N_FEATURES),
        .ADDR_W    (FEATURE_ADDR_W)
    ) u_feature_buffer (
        .clk    (clk),
        .rst_n  (rst_n),

        .wr_en  (feature_wr_en),
        .wr_addr(feature_wr_addr),
        .wr_data(feature_wr_data),

        .rd_addr(feature_rd_addr),
        .rd_data(feature_rd_data)
    );

    mlp_core #(
        .N_FEATURES(N_FEATURES),
        .FEATURE_W (FEATURE_W),
        .N_OUTPUTS (N_OUTPUTS),
        .OUTPUT_W  (OUTPUT_W)
    ) u_mlp_core (
        .clk       (clk),
        .rst_n     (rst_n),

        .mlp_start (mlp_start),
        .features_i(features),

        .mlp_busy  (mlp_busy),
        .mlp_done  (mlp_done),
        .result_o  (mlp_result)
    );

    // 8비트 uart_tx를 직접 연결하는 곳이 아니다.
    // 결과 전체를 바이트로 나누는 packet_tx가 필요하다.
    uart_packet_tx #(
        .N_OUTPUTS  (N_OUTPUTS),
        .OUTPUT_W   (OUTPUT_W),
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_packet_tx (
        .clk     (clk),
        .rst_n   (rst_n),

        .result_i(result_hold),
        .valid_i (tx_valid),
        .ready_o (tx_ready),

        .done_o  (tx_done),
        .tx_o    (uart_tx_o)
    );

    // ---------------------------------------------------------
    // 전체 실행 FSM
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            feature_idx      <= '0;
            rx_features_hold <= '0;
            features         <= '0;
            result_hold      <= '0;

            done             <= 1'b0;
            error            <= 1'b0;
        end else begin
            // 완료 신호는 기본적으로 0.
            // 완료 처리 시 한 사이클만 1로 만든다.
            done <= 1'b0;

            // 오류 기록은 리셋까지 유지한다.
            if (rx_error)
                error <= 1'b1;

            case (state)

                // 1. 정상 입력 패킷 수락
                IDLE: begin
                    if (accept_packet) begin
                        rx_features_hold <= rx_features;
                        feature_idx      <= '0;
                        state            <= STORE_FEATURES;
                    end
                end

                // 2. 매 상승 에지마다 Feature 하나 저장
                //
                // 실제 쓰기는 feature_buffer에서 수행한다.
                // 여기서는 다음 저장 주소를 제어한다.
                STORE_FEATURES: begin
                    if (feature_idx == N_FEATURES - 1) begin
                        feature_idx <= '0;
                        state       <= LOAD_FEATURES;
                    end else begin
                        feature_idx <= feature_idx + 1'b1;
                    end
                end

                // 3. Buffer를 읽어 MLP 입력 벡터 구성
                //
                // 현재 feature_buffer는 조합 읽기이므로,
                // rd_addr에 해당하는 값이 이 에지 전에 준비된다.
                // 동기 읽기 Buffer로 변경하면 대기 상태가 필요하다.
                LOAD_FEATURES: begin
                    features[
                        feature_idx * FEATURE_W +: FEATURE_W
                    ] <= feature_rd_data;

                    if (feature_idx == N_FEATURES - 1) begin
                        feature_idx <= '0;
                        state       <= START_CORE;
                    end else begin
                        feature_idx <= feature_idx + 1'b1;
                    end
                end

                // 4. 전체 입력 준비 후 MLP 시작
                //
                // 이 상태에서 mlp_start가 1이 되고,
                // MLP가 수락하는 에지에 WAIT_CORE로 이동한다.
                START_CORE: begin
                    if (!mlp_busy)
                        state <= WAIT_CORE;
                end

                // 5. 계산 완료 시 최종 결과 보관
                WAIT_CORE: begin
                    if (mlp_done) begin
                        result_hold <= mlp_result;
                        state       <= SEND_RESULT;
                    end
                end

                // 6. TX가 결과를 수락할 때까지
                // result_hold와 tx_valid 유지
                SEND_RESULT: begin
                    if (tx_ready) begin
                        if (tx_done) begin
                            state <= IDLE;
                            done  <= 1'b1;
                        end else begin
                            state <= WAIT_TX;
                        end
                    end
                end

                // 7. 마지막 바이트의 실제 송신 완료 대기
                WAIT_TX: begin
                    if (tx_done) begin
                        state <= IDLE;
                        done  <= 1'b1;
                    end
                end

                default: begin
                    state       <= IDLE;
                    feature_idx <= '0;
                    error       <= 1'b1;
                end

            endcase
        end
    end

endmodule

`default_nettype wire
