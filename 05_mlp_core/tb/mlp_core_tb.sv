`timescale 1ns / 1ps

// ============================================================================
// Testbench: mlp_core_tb
// Description:
//   - Part 1: 공통 기능 검증 (TC 1 ~ TC 8) -> 3-Buffer 코어 호환
//   - Part 2: 2-Buffer (Shared Layer Buffer) 전용 검증 (TC 9 ~ TC 11)
// ============================================================================

module mlp_core_tb;

    // -------------------------------------------------------------
    // 파라미터 정의
    // -------------------------------------------------------------
    localparam int FEATURE_W      = 8;
    localparam int WEIGHT_W       = 8;
    localparam int BIAS_W         = 32;
    localparam int ACC_W          = 32;
    localparam int N_MAC          = 8;

    localparam int N_INPUTS       = 5;
    localparam int N_NEURONS_L1   = 16;
    localparam int N_NEURONS_L2   = 8;
    localparam int N_NEURONS_L3   = 1;
    localparam int N_MAX          = 16;

    localparam int FEAT_ADDR_W    = 3;
    localparam int BUF_ADDR_W     = 4;

    localparam int IN_FRAC        = 8;
    localparam int OUT_FRAC       = 4;
    localparam time CLK_PERIOD    = 10ns;
    localparam time WATCHDOG_TIME = 50us;

    // -------------------------------------------------------------
    // 신호 정의
    // -------------------------------------------------------------
    logic                                  clk;
    logic                                  rstn;

    logic                                  i_feat_wr_en;
    logic [FEAT_ADDR_W-1:0]                i_feat_wr_addr;
    logic signed [FEATURE_W-1:0]           i_feat_wr_data;

    logic [1:0]                            i_layer_sel;
    logic                                  i_dense_start;
    logic                                  o_dense_done;
    logic                                  i_buf_wr_en;
    logic [BUF_ADDR_W-1:0]                 i_buf_wr_addr;

    logic signed [ACC_W-1:0]               o_mlp_data;

    int error_count = 0;

    // -------------------------------------------------------------
    // DUT 인스턴스화
    // -------------------------------------------------------------
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
        .L1_WMEM_FILE  (""),
        .L1_BMEM_FILE  (""),
        .L2_WMEM_FILE  (""),
        .L2_BMEM_FILE  (""),
        .L3_WMEM_FILE  (""),
        .L3_BMEM_FILE  ("")
    ) dut (
        .i_clk         (clk),
        .i_rstn        (rstn),
        .i_feat_wr_en  (i_feat_wr_en),
        .i_feat_wr_addr(i_feat_wr_addr),
        .i_feat_wr_data(i_feat_wr_data),
        .i_layer_sel   (i_layer_sel),
        .i_dense_start (i_dense_start),
        .o_dense_done  (o_dense_done),
        .i_buf_wr_en   (i_buf_wr_en),
        .i_buf_wr_addr (i_buf_wr_addr),
        .o_mlp_data    (o_mlp_data)
    );

    // 클럭 생성 (100MHz)
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // 데드락 방지 워치독 타이머
    initial begin
        #WATCHDOG_TIME;
        $display("\n********************************************************");
        $error(" [CORE TB WATCHDOG] 코어 시뮬레이션 타임아웃(%0t) 초과로 강제 종료!", WATCHDOG_TIME);
        $display("********************************************************");
        $finish;
    end

    // -------------------------------------------------------------
    // Golden Math Model
    // -------------------------------------------------------------
    function automatic logic signed [FEATURE_W-1:0] golden_requant(logic signed [ACC_W-1:0] acc_val);
        logic signed [ACC_W-1:0] relu_val;
        logic signed [ACC_W-1:0] rounded;
        logic signed [ACC_W-1:0] shifted;
        localparam int SHIFT = IN_FRAC - OUT_FRAC; // 4
        localparam logic signed [ACC_W-1:0] MAX_V = 127;
        localparam logic signed [ACC_W-1:0] MIN_V = -128;

        relu_val = (acc_val < 0) ? '0 : acc_val;
        rounded  = relu_val + (1 << (SHIFT - 1)); // +8 (Round-half-up)
        shifted  = rounded >>> SHIFT;

        if (shifted > MAX_V) return MAX_V[FEATURE_W-1:0];
        else if (shifted < MIN_V) return MIN_V[FEATURE_W-1:0];
        else return shifted[FEATURE_W-1:0];
    endfunction

    logic signed [WEIGHT_W-1:0] gold_w1 [0:N_NEURONS_L1-1][0:N_INPUTS-1];
    logic signed [BIAS_W-1:0]   gold_b1 [0:N_NEURONS_L1-1];
    logic signed [WEIGHT_W-1:0] gold_w2 [0:N_NEURONS_L2-1][0:N_NEURONS_L1-1];
    logic signed [BIAS_W-1:0]   gold_b2 [0:N_NEURONS_L2-1];
    logic signed [WEIGHT_W-1:0] gold_w3 [0:N_NEURONS_L3-1][0:N_NEURONS_L2-1];
    logic signed [BIAS_W-1:0]   gold_b3 [0:N_NEURONS_L3-1];

    // 가중치 및 편향 메모리 직접 로더
    task automatic load_memories();
        for (int g = 0; g < 2; g++) begin
            for (int f = 0; f < N_MAX; f++) begin
                logic [63:0] packed_w = '0;
                for (int m = 0; m < N_MAC; m++) begin
                    int n_idx = g * N_MAC + m;
                    if (n_idx < N_NEURONS_L1 && f < N_INPUTS)
                        packed_w[m*8 +: 8] = gold_w1[n_idx][f];
                end
                dut.u_wmem_l1.mem[g * N_MAX + f] = packed_w;
            end
            begin
                logic [255:0] packed_b = '0;
                for (int m = 0; m < N_MAC; m++) begin
                    int n_idx = g * N_MAC + m;
                    if (n_idx < N_NEURONS_L1)
                        packed_b[m*32 +: 32] = gold_b1[n_idx];
                end
                dut.u_bmem_l1.mem[g] = packed_b;
            end
        end

        for (int f = 0; f < N_MAX; f++) begin
            logic [63:0] packed_w = '0;
            for (int m = 0; m < N_MAC; m++) begin
                if (m < N_NEURONS_L2 && f < N_NEURONS_L1)
                    packed_w[m*8 +: 8] = gold_w2[m][f];
            end
            dut.u_wmem_l2.mem[f] = packed_w;
        end
        begin
            logic [255:0] packed_b = '0;
            for (int m = 0; m < N_MAC; m++) begin
                if (m < N_NEURONS_L2)
                    packed_b[m*32 +: 32] = gold_b2[m];
            end
            dut.u_bmem_l2.mem[0] = packed_b;
        end

        for (int f = 0; f < N_MAX; f++) begin
            logic [63:0] packed_w = '0;
            if (f < N_NEURONS_L2)
                packed_w[0*8 +: 8] = gold_w3[0][f];
            dut.u_wmem_l3.mem[f] = packed_w;
        end
        begin
            logic [255:0] packed_b = '0;
            packed_b[0*32 +: 32] = gold_b3[0];
            dut.u_bmem_l3.mem[0] = packed_b;
        end
    endtask

    task automatic reset_dut();
        rstn           <= 1'b0;
        i_feat_wr_en   <= 1'b0;
        i_feat_wr_addr <= '0;
        i_feat_wr_data <= '0;
        i_layer_sel    <= 2'd0;
        i_dense_start  <= 1'b0;
        i_buf_wr_en    <= 1'b0;
        i_buf_wr_addr  <= '0;
        repeat (5) @(posedge clk);
        rstn <= 1'b1;
        repeat (2) @(posedge clk);
    endtask

    // -------------------------------------------------------------
    // 컨트롤러 핸드셰이크 정밀 에뮬레이션
    // -------------------------------------------------------------
    task automatic run_pipeline(
        input  logic signed [FEATURE_W-1:0] test_inputs [0:N_INPUTS-1],
        output logic signed [ACC_W-1:0]     actual_l3_out
    );
        // Step 1. Feature Write (UART 에뮬레이션)
        for (int i = 0; i < N_INPUTS; i++) begin
            @(posedge clk);
            i_feat_wr_en   <= 1'b1;
            i_feat_wr_addr <= i[FEAT_ADDR_W-1:0];
            i_feat_wr_data <= test_inputs[i];
        end
        @(posedge clk);
        i_feat_wr_en <= 1'b0;

        // Step 2. Layer 1 구동 및 버퍼 쓰기
        i_layer_sel   <= 2'd0;
        @(posedge clk);
        i_dense_start <= 1'b1;
        @(posedge clk);
        i_dense_start <= 1'b0;
        
        wait(o_dense_done);
        @(posedge clk);
        i_buf_wr_en <= 1'b1;
        for (int a = 0; a < N_NEURONS_L1; a++) begin
            i_buf_wr_addr <= a[BUF_ADDR_W-1:0];
            @(posedge clk);
        end
        i_buf_wr_en   <= 1'b0;
        i_buf_wr_addr <= '0;

        // Step 3. Layer 2 구동 및 버퍼 쓰기
        i_layer_sel   <= 2'd1;
        @(posedge clk);
        i_dense_start <= 1'b1;
        @(posedge clk);
        i_dense_start <= 1'b0;
        
        wait(o_dense_done);
        @(posedge clk);
        i_buf_wr_en <= 1'b1;
        for (int a = 0; a < N_NEURONS_L2; a++) begin
            i_buf_wr_addr <= a[BUF_ADDR_W-1:0];
            @(posedge clk);
        end
        i_buf_wr_en   <= 1'b0;
        i_buf_wr_addr <= '0;

        // Step 4. Layer 3 구동 및 출력 데이터 취득
        i_layer_sel   <= 2'd2;
        @(posedge clk);
        i_dense_start <= 1'b1;
        @(posedge clk);
        i_dense_start <= 1'b0;
        
        wait(o_dense_done);
        @(posedge clk);
        actual_l3_out = o_mlp_data;
        @(posedge clk);
    endtask

    // -------------------------------------------------------------
    // 메인 시뮬레이션 시나리오
    // -------------------------------------------------------------
    initial begin
        logic signed [FEATURE_W-1:0] test_feat [0:N_INPUTS-1];
        logic signed [ACC_W-1:0]     expected_l1_acc [0:N_NEURONS_L1-1];
        logic signed [FEATURE_W-1:0] expected_l1_req [0:N_NEURONS_L1-1];
        logic signed [ACC_W-1:0]     expected_l2_acc [0:N_NEURONS_L2-1];
        logic signed [FEATURE_W-1:0] expected_l2_req [0:N_NEURONS_L2-1];
        logic signed [ACC_W-1:0]     expected_l3_acc;
        logic signed [ACC_W-1:0]     actual_result;
        logic signed [FEATURE_W-1:0] l1_snapshot [0:N_MAX-1];

        $display("\n========================================================");
        $display("   MLP Core 공통(TC 1~8) 및 2-Buffer 전용(TC 9~11) 전수 무결성 검증");
        $display("========================================================");

        // =========================================================
        // [Part 1] 공통 기능 검증 (TC 1 ~ TC 8) - 3-Buffer 호환
        // =========================================================

        // [TC 1] 표준 파이프라인 무결성 검증
        $display("\n[TC 1] [공통] 표준 파이프라인 무결성 검증");
        reset_dut();
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            gold_b1[n] = n * 5;
            for (int k = 0; k < N_INPUTS; k++) gold_w1[n][k] = (n + k) % 7 - 3;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            gold_b2[n] = n * 10;
            for (int k = 0; k < N_NEURONS_L1; k++) gold_w2[n][k] = (n * 2 - k) % 5;
        end
        gold_b3[0] = 500;
        for (int k = 0; k < N_NEURONS_L2; k++) gold_w3[0][k] = k + 1;
        load_memories();

        test_feat = '{8'sd10, -8'sd5, 8'sd8, 8'sd2, -8'sd4};
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            expected_l1_acc[n] = gold_b1[n];
            for (int k = 0; k < N_INPUTS; k++) expected_l1_acc[n] += test_feat[k] * gold_w1[n][k];
            expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc) begin
            $error("  [FAIL] TC 1 불일치! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 1 성공! L3 누적값: %0d", actual_result);

        // [TC 2] Zero input + bias 전파 및 음수 바이어스의 ReLU 0 Clamping 동시 검증
        $display("\n[TC 2] [공통] Zero Input 시 Bias 전달 및 음수 ReLU(0) Clamping 동시 검증");
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            gold_b1[n] = (n % 2 == 0) ? 32'sd50 : -32'sd50;
            for (int k = 0; k < N_INPUTS; k++) gold_w1[n][k] = 1;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            gold_b2[n] = 0;
            for (int k = 0; k < N_NEURONS_L1; k++) gold_w2[n][k] = 1;
        end
        gold_b3[0] = 0;
        for (int k = 0; k < N_NEURONS_L2; k++) gold_w3[0][k] = 1;
        load_memories();

        test_feat = '{8'sd0, 8'sd0, 8'sd0, 8'sd0, 8'sd0};
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            expected_l1_acc[n] = gold_b1[n];
            expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
            if (n % 2 != 0 && expected_l1_req[n] !== 0) begin
                $error("  [FAIL] TC 2 음수 ReLU 미작동! 뉴런 %0d: %0d", n, expected_l1_req[n]);
                error_count++;
            end
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc) begin
            $error("  [FAIL] TC 2 불일치! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 2 성공! 양수 편향 전달 및 음수 편향 0 클램핑 확인");

        // [TC 3] Requantize +127 상한 포화(Saturation) 정밀 검증
        $display("\n[TC 3] [공통] Requantize +127 상한 포화(Saturation) 정밀 검증");
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            gold_b1[n] = 32'sd50000;
            for (int k = 0; k < N_INPUTS; k++) gold_w1[n][k] = 8'sd10;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            gold_b2[n] = 0;
            for (int k = 0; k < N_NEURONS_L1; k++) gold_w2[n][k] = 1;
        end
        gold_b3[0] = 0;
        for (int k = 0; k < N_NEURONS_L2; k++) gold_w3[0][k] = 1;
        load_memories();

        test_feat = '{8'sd10, 8'sd10, 8'sd10, 8'sd10, 8'sd10};
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            expected_l1_acc[n] = gold_b1[n];
            for (int k = 0; k < N_INPUTS; k++) expected_l1_acc[n] += test_feat[k] * gold_w1[n][k];
            expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
            if (expected_l1_req[n] !== 8'sd127) begin
                $error("  [FAIL] TC 3 골든 모델 +127 포화 실패! 값: %0d", expected_l1_req[n]);
                error_count++;
            end
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc) begin
            $error("  [FAIL] TC 3 불일치! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 3 성공! L1 전체 뉴런 +127 상한 포화 완벽 작동");

        // [TC 4] L3 무-ReLU 경로의 음수 출력 및 32-bit 부호 확장 검증
        $display("\n[TC 4] [공통] L3 무-ReLU 경로의 음수 출력 및 32-bit 부호 확장 검증");
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            gold_b1[n] = 32'sd100;
            for (int k = 0; k < N_INPUTS; k++) gold_w1[n][k] = 0;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            gold_b2[n] = 32'sd50;
            for (int k = 0; k < N_NEURONS_L1; k++) gold_w2[n][k] = 1;
        end
        gold_b3[0] = -32'sd500000;
        for (int k = 0; k < N_NEURONS_L2; k++) gold_w3[0][k] = -8'sd5;
        load_memories();

        test_feat = '{8'sd0, 8'sd0, 8'sd0, 8'sd0, 8'sd0};
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            expected_l1_acc[n] = gold_b1[n];
            expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc || actual_result >= 0) begin
            $error("  [FAIL] TC 4 불일치! 음수 출력 부호 왜곡! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 4 성공! 음수 SOH 출력 정상 유지 (%0d)", actual_result);

        // [TC 5] Round-half-up 반올림 경계 (7:버림, 8:올림, 9:올림) 정밀 검증
        $display("\n[TC 5] [공통] Round-half-up 반올림 경계 (7:버림, 8:올림, 9:올림) 정밀 검증");
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            case (n)
                0: gold_b1[n] = 7;
                1: gold_b1[n] = 8;
                2: gold_b1[n] = 9;
                3: gold_b1[n] = 23;
                4: gold_b1[n] = 24;
                default: gold_b1[n] = 0;
            endcase
            for (int k = 0; k < N_INPUTS; k++) gold_w1[n][k] = 0;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            gold_b2[n] = 0;
            for (int k = 0; k < N_NEURONS_L1; k++) gold_w2[n][k] = (k == n) ? 1 : 0;
        end
        gold_b3[0] = 0;
        for (int k = 0; k < N_NEURONS_L2; k++) gold_w3[0][k] = 1;
        load_memories();

        test_feat = '{8'sd0, 8'sd0, 8'sd0, 8'sd0, 8'sd0};
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            expected_l1_acc[n] = gold_b1[n];
            expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
        end
        if (expected_l1_req[0] !== 0 || expected_l1_req[1] !== 1 || expected_l1_req[2] !== 1 ||
            expected_l1_req[3] !== 1 || expected_l1_req[4] !== 2) begin
            $error("  [FAIL] TC 5 반올림 7/8/9 경계값 불일치!");
            error_count++;
        end

        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc) begin
            $error("  [FAIL] TC 5 최종 파이프라인 불일치! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 5 성공! 7(0), 8(1), 9(1), 23(1), 24(2) 반올림 경계 100%% 일치");

        // [TC 6] 32-bit 상한 근처 연산 및 부호 확장 정합성 검증 (Golden 64-bit 독립 감시)
        $display("\n[TC 6] [공통] 32-bit 상한 근처 연산 및 부호 확장 정합성 검증");
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            gold_b1[n] = 32'sh7FFF_E000;
            for (int k = 0; k < N_INPUTS; k++) gold_w1[n][k] = 8'sd10;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            gold_b2[n] = 0;
            for (int k = 0; k < N_NEURONS_L1; k++) gold_w2[n][k] = 1;
        end
        gold_b3[0] = 0;
        for (int k = 0; k < N_NEURONS_L2; k++) gold_w3[0][k] = 1;
        load_memories();

        test_feat = '{8'sd10, 8'sd10, 8'sd10, 8'sd10, 8'sd10};

        begin
            longint signed gold64_acc;
            for (int n = 0; n < N_NEURONS_L1; n++) begin
                gold64_acc = gold_b1[n];
                for (int k = 0; k < N_INPUTS; k++) gold64_acc += test_feat[k] * gold_w1[n][k];
                
                if (gold64_acc > 64'sh7FFF_FFFF || gold64_acc < -64'sh8000_0000) begin
                    $error("  [TESTBENCH CONFIG ERROR] TC 6 설정값이 32비트 범위를 벗어났습니다!");
                end
                expected_l1_acc[n] = gold64_acc[31:0];
                expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
            end
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc) begin
            $error("  [FAIL] TC 6 32-bit 부호 확장 연산 불일치! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 6 성공! 32비트 상한 근처 표현 영역 연산 정합성 입증");

        // [TC 7] 리셋 없는 Back-to-Back 덮어쓰기 검증
        $display("\n[TC 7] [공통] 리셋 없는 연속 추론 시 이전 잔류 데이터 덮어쓰기(Overwrite) 검증");
        test_feat = '{8'sd1, 8'sd2, 8'sd3, 8'sd4, 8'sd5};
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            expected_l1_acc[n] = gold_b1[n];
            for (int k = 0; k < N_INPUTS; k++) expected_l1_acc[n] += test_feat[k] * gold_w1[n][k];
            expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc) begin
            $error("  [FAIL] TC 7 불일치! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 7 성공! 2회차 추론 시 공유버퍼 완전 갱신 확인");

        // [TC 8] Feature Buffer 비사용 슬롯(5~15) 쓰레기 데이터 격리
        $display("\n[TC 8] [공통] Feature Buffer 비사용 슬롯(5~15) 쓰레기 데이터 격리 검증");
        reset_dut();
        load_memories(); // 명시적 재적재를 통한 TC 8 단독 실행/격리 독립성 보장
        for (int b = N_INPUTS; b < N_MAX; b++) begin
            dut.u_feature_buffer.o_feature[b] = 8'sd127;
        end
        test_feat = '{8'sd5, 8'sd5, 8'sd5, 8'sd5, 8'sd5};
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            expected_l1_acc[n] = gold_b1[n];
            for (int k = 0; k < N_INPUTS; k++) expected_l1_acc[n] += test_feat[k] * gold_w1[n][k];
            expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc) begin
            $error("  [FAIL] TC 8 불일치! Feature Buffer 경계 오버런! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 8 성공! Feature Buffer 0~4번만 정확히 읽음 확인");

        // =========================================================
        // [Part 2] 2-Buffer (Shared Layer Buffer) 전용 검증 (TC 9 ~ TC 11)
        // =========================================================

        // [TC 9] Shared Buffer 2:1 Write MUX 라우팅 런타임 단정 검증
        $display("\n[TC 9] [2-Buffer 전용] Shared Buffer 2:1 Write MUX 라우팅 런타임 단정 검증");
        begin
            int tc9_err_before = error_count;

            fork
                begin
                    run_pipeline(test_feat, actual_result);
                end

                begin
                    // L1 쓰기 MUX 감시
                    wait(i_buf_wr_en && (i_layer_sel == 2'd0));
                    while (i_buf_wr_en) begin
                        @(negedge clk);
                        if (dut.shared_buf_wr_data !== dut.l1_requant_out[i_buf_wr_addr]) begin
                            $error("  [FAIL] TC 9: L1 쓰기 MUX 불일치! addr=%0d", i_buf_wr_addr);
                            error_count++;
                        end
                        @(posedge clk);
                    end

                    // L2 쓰기 MUX 감시
                    wait(i_buf_wr_en && (i_layer_sel == 2'd1));
                    while (i_buf_wr_en) begin
                        @(negedge clk);
                        if (dut.shared_buf_wr_data !== dut.l2_requant_out[i_buf_wr_addr[2:0]]) begin
                            $error("  [FAIL] TC 9: L2 쓰기 MUX 불일치! addr=%0d", i_buf_wr_addr);
                            error_count++;
                        end
                        @(posedge clk);
                    end
                end
            join

            if (error_count == tc9_err_before) begin
                $display("  [PASS] TC 9 성공! L1/L2 MUX 실시간 라우팅 단정문 전수 통과");
            end else begin
                $display("  [FAIL] TC 9 실패! MUX 라우팅 오류 발생");
            end
        end

        // [TC 10] Shared Buffer 뒤쪽 잔여 데이터(8~15) 미참조 격리
        $display("\n[TC 10] [2-Buffer 전용] Shared Buffer 8~15번 잔여 데이터(Stale Data) 완벽 격리 검증");
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            gold_b1[n] = 50;
            for (int k = 0; k < N_INPUTS; k++) gold_w1[n][k] = 2;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            gold_b2[n] = -10;
            for (int k = 0; k < N_NEURONS_L1; k++) begin
                gold_w2[n][k] = (k < 8) ? 3 : -10;
            end
        end
        gold_b3[0] = 100;
        for (int k = 0; k < N_NEURONS_L2; k++) gold_w3[0][k] = 4;
        load_memories();

        test_feat = '{8'sd15, 8'sd10, 8'sd5, 8'sd2, 8'sd1};
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            expected_l1_acc[n] = gold_b1[n];
            for (int k = 0; k < N_INPUTS; k++) expected_l1_acc[n] += test_feat[k] * gold_w1[n][k];
            expected_l1_req[n] = golden_requant(expected_l1_acc[n]);
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            expected_l2_acc[n] = gold_b2[n];
            for (int k = 0; k < N_NEURONS_L1; k++) expected_l2_acc[n] += expected_l1_req[k] * gold_w2[n][k];
            expected_l2_req[n] = golden_requant(expected_l2_acc[n]);
        end
        expected_l3_acc = gold_b3[0];
        for (int k = 0; k < N_NEURONS_L2; k++) expected_l3_acc += expected_l2_req[k] * gold_w3[0][k];

        run_pipeline(test_feat, actual_result);
        if (actual_result !== expected_l3_acc) begin
            $error("  [FAIL] TC 10 불일치! Stale 데이터 누출 감지! 기대: %0d, 실제: %0d", expected_l3_acc, actual_result);
            error_count++;
        end else $display("  [PASS] TC 10 성공! Shared Buffer 8~15번 stale data가 최종 결과에 영향을 주지 않음: %0d", actual_result);

        // [TC 11] Shared Buffer 메모리 직접 비교를 통한 Cross-talk 무결성 검증
        $display("\n[TC 11] [2-Buffer 전용] Shared Buffer 메모리 직접 비교를 통한 Cross-talk 무결성 검증");
        begin
            int tc11_err_before = error_count;

            fork
                begin
                    run_pipeline(test_feat, actual_result);
                end

                begin
                    // 1. L1 쓰기가 끝나는 시점에 0~15번 전체 스냅샷 저장
                    wait(i_buf_wr_en && (i_layer_sel == 2'd0));
                    wait(!i_buf_wr_en);
                    @(negedge clk);
                    for (int i = 0; i < N_MAX; i++) begin
                        l1_snapshot[i] = dut.u_shared_layer_buffer1.o_data[i];
                    end

                    // 2. L2 쓰기가 끝나는 시점에 8~15번이 보존되었는지 검사
                    wait(i_buf_wr_en && (i_layer_sel == 2'd1));
                    wait(!i_buf_wr_en);
                    @(negedge clk);
                    for (int i = 8; i < N_MAX; i++) begin
                        if (dut.u_shared_layer_buffer1.o_data[i] !== l1_snapshot[i]) begin
                            $error("  [FAIL] TC 11 Cross-talk 발생! 슬롯 %0d번 오염! 기존: %0d, 현재: %0d", 
                                   i, l1_snapshot[i], dut.u_shared_layer_buffer1.o_data[i]);
                            error_count++;
                        end
                    end
                end
            join

            if (error_count == tc11_err_before) begin
                $display("  [PASS] TC 11 성공! L2 쓰기 시 8~15번 슬롯 데이터 손상 부재(Cross-talk 0건) 확인");
            end else begin
                $display("  [FAIL] TC 11 실패! Shared Buffer 잔여 슬롯 오염 감지");
            end
        end

        // -------------------------------------------------------------
        // 최종 요약 보고
        // -------------------------------------------------------------
        $display("\n********************************************************");
        if (error_count == 0) begin
            $display("   [ALL 11 TEST CASES PASSED] Core 무결성 검증 완료!");
            $display("   - Part 1 (공통): TC 1~8 산술/양자화/파이프라인 무결성 100%% 일치");
            $display("   - Part 2 (2-Buffer): TC 9~11 MUX 라우팅, Stale Data 격리, Cross-talk 부재 검증 완료");
        end else begin
            $display("   [CORE TEST FAILED] 총 %0d건의 오류 발생!", error_count);
        end
        $display("********************************************************\n");
        $finish;
    end

endmodule
