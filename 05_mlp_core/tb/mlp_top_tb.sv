`timescale 1ns / 1ps

module mlp_top_tb;

    // =========================================================================
    // 1. 파라미터 및 인터페이스 선언
    // =========================================================================
    localparam CLK_PERIOD     = 10; // 100MHz (10ns)
    localparam FEATURE_W      = 8;
    localparam WEIGHT_W       = 8;
    localparam BIAS_W         = 32;
    localparam ACC_W          = 32;
    localparam N_MAC          = 8;
    localparam N_INPUTS       = 5;
    localparam N_NEURONS_L1   = 16;
    localparam N_NEURONS_L2   = 8;
    localparam N_NEURONS_L3   = 1;
    localparam N_MAX          = 16;
    localparam FEAT_ADDR_W    = $clog2(N_INPUTS); // 3-bit
    localparam BUF_ADDR_W     = 4;
    localparam IN_FRAC        = 8;
    localparam OUT_FRAC       = 4;

    logic                           clk;
    logic                           rstn;
    logic                           i_mlp_start;
    logic                           o_mlp_busy;
    logic                           o_mlp_done;

    logic                           i_feat_wr_en;
    logic [FEAT_ADDR_W-1:0]         i_feat_wr_addr;
    logic signed [FEATURE_W-1:0]    i_feat_wr_data;

    logic signed [ACC_W-1:0]        o_soh_data;

    // 검증 모니터링 변수
    int                             test_cnt = 0;
    int                             pass_cnt = 0;
    int                             fail_cnt = 0;

    // 골든 모델 저장용 배열
    logic signed [FEATURE_W-1:0]    tb_features [0:N_INPUTS-1];
    logic signed [WEIGHT_W-1:0]     tb_w1 [0:N_NEURONS_L1-1][0:N_INPUTS-1];
    logic signed [BIAS_W-1:0]       tb_b1 [0:N_NEURONS_L1-1];
    logic signed [WEIGHT_W-1:0]     tb_w2 [0:N_NEURONS_L2-1][0:N_NEURONS_L1-1];
    logic signed [BIAS_W-1:0]       tb_b2 [0:N_NEURONS_L2-1];
    logic signed [WEIGHT_W-1:0]     tb_w3 [0:N_NEURONS_L3-1][0:N_NEURONS_L2-1];
    logic signed [BIAS_W-1:0]       tb_b3 [0:N_NEURONS_L3-1];

    // =========================================================================
    // 2. DUT 인스턴스
    // =========================================================================
    mlp_top #(
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
        .i_mlp_start   (i_mlp_start),
        .o_mlp_busy    (o_mlp_busy),
        .o_mlp_done    (o_mlp_done),
        .i_feat_wr_en  (i_feat_wr_en),
        .i_feat_wr_addr(i_feat_wr_addr),
        .i_feat_wr_data(i_feat_wr_data),
        .o_soh_data    (o_soh_data)
    );

    // =========================================================================
    // 3. 클럭 생성 (100MHz)
    // =========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // =========================================================================
    // 4. 소프트웨어 골든 모델 함수
    // =========================================================================
    function automatic logic signed [FEATURE_W-1:0] requant_relu(input logic signed [ACC_W-1:0] val);
        logic signed [ACC_W-1:0] relu_val;
        logic signed [ACC_W-1:0] round_val;
        logic signed [ACC_W-1:0] shift_val;
        int shift_amt = IN_FRAC - OUT_FRAC; // 4
        int max_val   = (1 << (FEATURE_W - 1)) - 1; // +127
        int min_val   = -(1 << (FEATURE_W - 1));    // -128

        relu_val  = (val < 0) ? 32'sd0 : val;
        round_val = relu_val + (32'sd1 << (shift_amt - 1));
        shift_val = round_val >>> shift_amt;

        if (shift_val > max_val)      return max_val[FEATURE_W-1:0];
        else if (shift_val < min_val) return min_val[FEATURE_W-1:0];
        else                          return shift_val[FEATURE_W-1:0];
    endfunction

    function automatic logic signed [ACC_W-1:0] compute_golden();
        logic signed [ACC_W-1:0]     l1_acc [0:N_NEURONS_L1-1];
        logic signed [FEATURE_W-1:0] l1_out [0:N_NEURONS_L1-1];
        logic signed [ACC_W-1:0]     l2_acc [0:N_NEURONS_L2-1];
        logic signed [FEATURE_W-1:0] l2_out [0:N_NEURONS_L2-1];
        logic signed [ACC_W-1:0]     l3_acc;

        // Layer 1
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            l1_acc[n] = tb_b1[n];
            for (int f = 0; f < N_INPUTS; f++) begin
                l1_acc[n] += 32'($signed(tb_features[f])) * 32'($signed(tb_w1[n][f]));
            end
            l1_out[n] = requant_relu(l1_acc[n]);
        end

        // Layer 2
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            l2_acc[n] = tb_b2[n];
            for (int f = 0; f < N_NEURONS_L1; f++) begin
                l2_acc[n] += 32'($signed(l1_out[f])) * 32'($signed(tb_w2[n][f]));
            end
            l2_out[n] = requant_relu(l2_acc[n]);
        end

        // Layer 3 (Output Layer Linear Pass-through)
        l3_acc = tb_b3[0];
        for (int f = 0; f < N_NEURONS_L2; f++) begin
            l3_acc += 32'($signed(l2_out[f])) * 32'($signed(tb_w3[0][f]));
        end

        return l3_acc;
    endfunction

    // =========================================================================
    // 5. 드라이버 및 제어 검증 Task
    // =========================================================================
    task automatic load_dut_parameters();
        for (int f = 0; f < N_MAX; f++) begin
            logic [63:0] w_packed_g0 = '0;
            logic [63:0] w_packed_g1 = '0;
            for (int g = 0; g < N_MAC; g++) begin
                if (f < N_INPUTS) begin
                    w_packed_g0[g*8 +: 8] = tb_w1[g][f];
                    w_packed_g1[g*8 +: 8] = tb_w1[g + N_MAC][f];
                end
            end
            dut.u_mlp_core.u_wmem_l1.mem[0 * N_MAX + f] = w_packed_g0;
            dut.u_mlp_core.u_wmem_l1.mem[1 * N_MAX + f] = w_packed_g1;
        end
        for (int g = 0; g < N_MAC; g++) begin
            dut.u_mlp_core.u_bmem_l1.mem[0][g*32 +: 32] = tb_b1[g];
            dut.u_mlp_core.u_bmem_l1.mem[1][g*32 +: 32] = tb_b1[g + N_MAC];
        end

        for (int f = 0; f < N_MAX; f++) begin
            logic [63:0] w_packed = '0;
            for (int g = 0; g < N_MAC; g++) begin
                if (f < N_NEURONS_L1)
                    w_packed[g*8 +: 8] = tb_w2[g][f];
            end
            dut.u_mlp_core.u_wmem_l2.mem[f] = w_packed;
        end
        for (int g = 0; g < N_MAC; g++)
            dut.u_mlp_core.u_bmem_l2.mem[0][g*32 +: 32] = tb_b2[g];

        for (int f = 0; f < N_MAX; f++) begin
            logic [63:0] w_packed = '0;
            if (f < N_NEURONS_L2)
                w_packed[0*8 +: 8] = tb_w3[0][f];
            dut.u_mlp_core.u_wmem_l3.mem[f] = w_packed;
        end
        dut.u_mlp_core.u_bmem_l3.mem[0] = '0;
        dut.u_mlp_core.u_bmem_l3.mem[0][31:0] = tb_b3[0];
    endtask

    task automatic drive_features(input logic signed [FEATURE_W-1:0] feats [0:N_INPUTS-1]);
        for (int i = 0; i < N_INPUTS; i++) begin
            @(posedge clk);
            i_feat_wr_en   <= 1'b1;
            i_feat_wr_addr <= i[FEAT_ADDR_W-1:0];
            i_feat_wr_data <= feats[i];
            tb_features[i] <= feats[i];
        end
        @(posedge clk);
        i_feat_wr_en <= 1'b0;
    endtask

    task automatic run_and_verify(
        input string tc_name, 
        input bit check_busy_ignore = 0,
        output bit pass_flag
    );
        logic signed [ACC_W-1:0] exp_out;
        bit error_occurred = 0;

        load_dut_parameters();

        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;

        #1;
        if (o_mlp_busy !== 1'b1) begin
            $error("[FAIL] %s | o_mlp_busy가 High로 전이되지 않음!", tc_name);
            error_occurred = 1;
        end

        // Busy 도중 Start 재인가 무시 테스트
        if (check_busy_ignore) begin
            repeat(4) @(posedge clk);
            i_mlp_start <= 1'b1;
            @(posedge clk);
            i_mlp_start <= 1'b0;
        end

        // 1. o_mlp_done 상승 에지 검출
        @(posedge o_mlp_done);

        // 2. 정확히 1클럭 펄스 검증: 다음 posedge clk 직후 0으로 클리어되어야 함
        @(posedge clk);
        #1;
        if (o_mlp_done !== 1'b0) begin
            $error("[FAIL] %s | o_mlp_done 펄스 폭이 1클럭을 초과함!", tc_name);
            error_occurred = 1;
        end

        // 3. Busy 신호 해제 검증
        if (o_mlp_busy !== 1'b0) begin
            $error("[FAIL] %s | o_mlp_done 이후 o_mlp_busy가 즉시 클리어되지 않음!", tc_name);
            error_occurred = 1;
        end

        // 4. 연산 결과 정합성 검증
        exp_out = compute_golden();
        if (o_soh_data !== exp_out) begin
            $error("[FAIL] %s | 결과 불일치! Expected: %0d (0x%08x), Got: %0d (0x%08x)", tc_name, exp_out, exp_out, o_soh_data, o_soh_data);
            error_occurred = 1;
        end

        pass_flag = ~error_occurred;
        if (pass_flag) begin
            $display("[PASS] %s | Result: %0d (0x%08x)", tc_name, o_soh_data, o_soh_data);
        end
    endtask

    task automatic execute_test(input string tc_name, input bit check_busy_ignore = 0);
        bit test_pass;
        test_cnt++;
        run_and_verify(tc_name, check_busy_ignore, test_pass);
        if (test_pass) pass_cnt++;
        else           fail_cnt++;
    endtask

    // =========================================================================
    // 6. 전체 테스트벤치 시나리오 실행
    // =========================================================================
    initial begin
        rstn           = 0;
        i_mlp_start    = 0;
        i_feat_wr_en   = 0;
        i_feat_wr_addr = 0;
        i_feat_wr_data = 0;

        // =====================================================================
        // [Part 1] 구조 공통 기능 검증 (TC 1 ~ TC 10)
        // =====================================================================
        $display("\n============================================================");
        $display("   [Part 1] COMMON FUNCTIONAL VERIFICATION (TC 1 ~ TC 10)   ");
        $display("============================================================");

        // -------------------------------------------------------------
        // TC 1: Reset 상태 점검
        // -------------------------------------------------------------
        test_cnt++;
        #(CLK_PERIOD * 3);
        if (o_mlp_busy !== 1'b0 || o_mlp_done !== 1'b0 || o_soh_data !== 32'sd0) begin
            $error("[FAIL] TC 1: Reset 중 상태 신호 비정상!");
            fail_cnt++;
        end else begin
            $display("[PASS] TC 1: Reset 상태 정상 (busy=0, done=0, soh=0)");
            pass_cnt++;
        end

        rstn = 1;
        #(CLK_PERIOD * 2);

        // -------------------------------------------------------------
        // TC 2: All Zero 기본 정합성
        // -------------------------------------------------------------
        for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd0;
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            tb_b1[n] = 32'sd0;
            for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = 8'sd0;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            tb_b2[n] = 32'sd0;
            for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = 8'sd0;
        end
        tb_b3[0] = 32'sd0;
        for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = 8'sd0;

        drive_features(tb_features);
        execute_test("TC 2: All Zero Baseline Test");

        // -------------------------------------------------------------
        // TC 3: Normal Positive 선형 연산
        // -------------------------------------------------------------
        for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd2;
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            tb_b1[n] = 32'sd0;
            for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = 8'sd1;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            tb_b2[n] = 32'sd0;
            for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = 8'sd1;
        end
        tb_b3[0] = 32'sd0;
        for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = 8'sd1;

        drive_features(tb_features);
        execute_test("TC 3: Normal Positive Mapping Test");

        // -------------------------------------------------------------
        // TC 4: L1 ReLU Zero-Clamping (L1 Accumulator < 0)
        // -------------------------------------------------------------
        for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd5;
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            tb_b1[n] = -32'sd500;
            for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = -8'sd2;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            tb_b2[n] = 32'sd0;
            for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = 8'sd1;
        end
        tb_b3[0] = 32'sd0;
        for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = 8'sd1;

        drive_features(tb_features);
        execute_test("TC 4: L1 ReLU Zero-Clamping Test");

        // -------------------------------------------------------------
        // TC 5: L2 ReLU Zero-Clamping (L1 > 0, L2 Accumulator < 0)
        // -------------------------------------------------------------
        for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd2;
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            tb_b1[n] = 32'sd0;
            for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = 8'sd1;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            tb_b2[n] = -32'sd5000;
            for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = -8'sd2;
        end
        tb_b3[0] = 32'sd0;
        for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = 8'sd1;

        drive_features(tb_features);
        execute_test("TC 5: L2 ReLU Zero-Clamping Test");

        // -------------------------------------------------------------
        // TC 6: Requantization Rounding Boundary (7 -> 0 및 8 -> 1 연속 검증)
        // -------------------------------------------------------------
        test_cnt++;
        begin
            bit tc6_p1, tc6_p2;

            // Step 1: 7 + 8 = 15 >>> 4 = 0 검증
            for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd0;
            for (int n = 0; n < N_NEURONS_L1; n++) begin
                tb_b1[n] = 32'sd7;
                for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = 8'sd0;
            end
            for (int n = 0; n < N_NEURONS_L2; n++) begin
                tb_b2[n] = 32'sd0;
                for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = 8'sd1;
            end
            tb_b3[0] = 32'sd0;
            for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = 8'sd1;
            drive_features(tb_features);
            run_and_verify("TC 6 (Step 1: 7 -> 0)", 0, tc6_p1);

            // Step 2: 8 + 8 = 16 >>> 4 = 1 검증
            for (int n = 0; n < N_NEURONS_L1; n++) begin
                tb_b1[n] = 32'sd8;
            end
            run_and_verify("TC 6 (Step 2: 8 -> 1)", 0, tc6_p2);

            if (tc6_p1 && tc6_p2) begin
                $display("[PASS] TC 6: Requantizer Rounding Boundary (7->0 and 8->1) Confirmed");
                pass_cnt++;
            end else begin
                fail_cnt++;
            end
        end

        // -------------------------------------------------------------
        // TC 7: Positive Saturation (+127 Clamping)
        // -------------------------------------------------------------
        for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd127;
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            tb_b1[n] = 32'sd100000;
            for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = 8'sd127;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            tb_b2[n] = 32'sd0;
            for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = 8'sd1;
        end
        tb_b3[0] = 32'sd0;
        for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = 8'sd1;

        drive_features(tb_features);
        execute_test("TC 7: Positive Saturation (+127 Clamping)");

        // -------------------------------------------------------------
        // TC 8: L3 Negative Output (Output Layer Linear Pass-through)
        // -------------------------------------------------------------
        for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd1;
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            tb_b1[n] = 32'sd0;
            for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = 8'sd1;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            tb_b2[n] = 32'sd0;
            for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = 8'sd1;
        end
        tb_b3[0] = -32'sd100;
        for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = -8'sd2;

        drive_features(tb_features);
        execute_test("TC 8: L3 Negative Linear Output (No ReLU on L3)");

        // -------------------------------------------------------------
        // TC 9: Busy 중 Start 재인가 무시 검증 (Busy Glitch Rejection)
        // -------------------------------------------------------------
        for (int i = 0; i < N_INPUTS; i++) tb_features[i] = i + 1;
        for (int n = 0; n < N_NEURONS_L1; n++) begin
            tb_b1[n] = 32'sd0;
            for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = 8'sd1;
        end
        for (int n = 0; n < N_NEURONS_L2; n++) begin
            tb_b2[n] = 32'sd0;
            for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = 8'sd1;
        end
        tb_b3[0] = 32'sd0;
        for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = 8'sd1;

        drive_features(tb_features);
        execute_test("TC 9: Busy Glitch Rejection (Ignore i_mlp_start during Busy)", 1'b1);

        // -------------------------------------------------------------
        // TC 10: Randomized Stress Test (20회 일괄 검증, Signed 엄밀화)
        // -------------------------------------------------------------
        $display("\n--- Starting TC 10: 20-Run Randomized Stress Testing ---");
        test_cnt++;
        begin
            bit all_random_pass = 1;
            for (int loop = 1; loop <= 20; loop++) begin
                bit single_pass;
                for (int i = 0; i < N_INPUTS; i++) 
                    tb_features[i] = $signed($urandom_range(0, 255)) - 8'sd128;

                for (int n = 0; n < N_NEURONS_L1; n++) begin
                    tb_b1[n] = $signed($urandom_range(0, 65535)) - 32'sd32768;
                    for (int f = 0; f < N_INPUTS; f++) 
                        tb_w1[n][f] = $signed($urandom_range(0, 255)) - 8'sd128;
                end

                for (int n = 0; n < N_NEURONS_L2; n++) begin
                    tb_b2[n] = $signed($urandom_range(0, 65535)) - 32'sd32768;
                    for (int f = 0; f < N_NEURONS_L1; f++) 
                        tb_w2[n][f] = $signed($urandom_range(0, 255)) - 8'sd128;
                end

                tb_b3[0] = $signed($urandom_range(0, 65535)) - 32'sd32768;
                for (int f = 0; f < N_NEURONS_L2; f++) 
                    tb_w3[0][f] = $signed($urandom_range(0, 255)) - 8'sd128;

                drive_features(tb_features);
                run_and_verify($sformatf("Random Run #%0d", loop), 0, single_pass);
                if (!single_pass) all_random_pass = 0;
            end

            if (all_random_pass) begin
                $display("[PASS] TC 10: 20 Randomized Stress Runs Completed Successfully");
                pass_cnt++;
            end else begin
                $error("[FAIL] TC 10: Random Stress Runs Failed!");
                fail_cnt++;
            end
        end

        // =====================================================================
        // [Part 2] Shared Layer Buffer 전용 검증 (TC 11 ~ TC 12)
        // =====================================================================
        $display("\n============================================================");
        $display("   [Part 2] SHARED LAYER BUFFER EXCLUSIVE (TC 11 ~ TC 12)   ");
        $display("============================================================");

        // -------------------------------------------------------------
        // TC 11: Shared Buffer L1/L2 Write Routing (주소 타입 슬라이스 명시 비교)
        // -------------------------------------------------------------
        test_cnt++;
        begin
            bit tc11_pass = 1;
            int l1_expected_addr = 0;
            int l2_expected_addr = 0;
            bit l1_seq_ok = 1;
            bit l2_seq_ok = 1;

            for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd3;
            for (int n = 0; n < N_NEURONS_L1; n++) begin
                tb_b1[n] = 32'sd0;
                for (int f = 0; f < N_INPUTS; f++) tb_w1[n][f] = 8'sd1;
            end
            for (int n = 0; n < N_NEURONS_L2; n++) begin
                tb_b2[n] = 32'sd0;
                for (int f = 0; f < N_NEURONS_L1; f++) tb_w2[n][f] = 8'sd1;
            end
            tb_b3[0] = 32'sd0;
            for (int f = 0; f < N_NEURONS_L2; f++) tb_w3[0][f] = 8'sd1;

            drive_features(tb_features);

            fork
                begin : tc11_routing_monitor
                    // L1 쓰기 구간 주소 시퀀스 검증 (0 -> 1 -> ... -> 15)
                    @(posedge clk iff (dut.u_mlp_core.i_layer_sel == 2'd0 && dut.u_mlp_core.i_buf_wr_en));
                    while (dut.u_mlp_core.i_buf_wr_en && dut.u_mlp_core.i_layer_sel == 2'd0) begin
                        if (dut.u_mlp_core.i_buf_wr_addr !== l1_expected_addr[BUF_ADDR_W-1:0]) begin
                            $error("[TC 11 FAIL] L1 쓰기 주소 순서 위반! Expected: %0d, Got: %0d", l1_expected_addr, dut.u_mlp_core.i_buf_wr_addr);
                            l1_seq_ok = 0;
                        end
                        l1_expected_addr++;
                        @(posedge clk);
                    end

                    // L2 쓰기 구간 주소 시퀀스 검증 (0 -> 1 -> ... -> 7)
                    @(posedge clk iff (dut.u_mlp_core.i_layer_sel == 2'd1 && dut.u_mlp_core.i_buf_wr_en));
                    while (dut.u_mlp_core.i_buf_wr_en && dut.u_mlp_core.i_layer_sel == 2'd1) begin
                        if (dut.u_mlp_core.i_buf_wr_addr !== l2_expected_addr[BUF_ADDR_W-1:0]) begin
                            $error("[TC 11 FAIL] L2 쓰기 주소 순서 위반! Expected: %0d, Got: %0d", l2_expected_addr, dut.u_mlp_core.i_buf_wr_addr);
                            l2_seq_ok = 0;
                        end
                        l2_expected_addr++;
                        @(posedge clk);
                    end
                end

                begin : tc11_inference_driver
                    bit core_pass;
                    run_and_verify("TC 11 Inference Execution", 0, core_pass);
                    if (!core_pass) tc11_pass = 0;
                end
            join

            if (!l1_seq_ok || !l2_seq_ok || l1_expected_addr !== N_NEURONS_L1 || l2_expected_addr !== N_NEURONS_L2) begin
                $error("[TC 11 FAIL] 주소 라우팅 시퀀스 오류! (L1 최종: %0d, L2 최종: %0d)", l1_expected_addr, l2_expected_addr);
                tc11_pass = 0;
            end

            if (tc11_pass) begin
                $display("[PASS] TC 11: Shared Buffer L1(0~15) & L2(0~7) Sequential Routing Confirmed");
                pass_cnt++;
            end else begin
                fail_cnt++;
            end
        end

        // -------------------------------------------------------------
        // TC 12: Shared Buffer Stale Data(8~15) 미침범 & Cross-talk 무결성 검증
        // -------------------------------------------------------------
        test_cnt++;
        begin
            bit tc12_pass = 1;
            bit timeout_occurred = 0;
            logic signed [7:0] stale_val [8:15];

            for (int i = 0; i < N_INPUTS; i++) tb_features[i] = 8'sd4;
            drive_features(tb_features);

            fork
                begin : main_test_group
                    fork
                        begin : crosstalk_monitor
                            // L1 쓰기 시작 대기
                            @(posedge clk iff (dut.u_mlp_core.i_layer_sel == 2'd0 && dut.u_mlp_core.i_buf_wr_en));
                            
                            // L1 쓰기 해제 검출
                            while (1) begin
                                @(posedge clk);
                                #1;
                                if (!dut.u_mlp_core.i_buf_wr_en) break;
                            end

                            // L1 최종 기록 안착 후 8~15번 슬롯 데이터 보관
                            for (int s = 8; s < 16; s++) begin
                                stale_val[s] = dut.u_mlp_core.u_shared_layer_buffer1.o_data[s];
                            end

                            // L2 쓰기 시작 대기
                            while (1) begin
                                @(posedge clk);
                                #1;
                                if (dut.u_mlp_core.i_layer_sel == 2'd1 && dut.u_mlp_core.i_buf_wr_en) break;
                            end

                            // L2 쓰기 진행 동안 8~15번 슬롯 변경 여부 감시
                            while (dut.u_mlp_core.i_buf_wr_en && dut.u_mlp_core.i_layer_sel == 2'd1) begin
                                for (int s = 8; s < 16; s++) begin
                                    if (dut.u_mlp_core.u_shared_layer_buffer1.o_data[s] !== stale_val[s]) begin
                                        $error("[TC 12 FAIL] L2 쓰기 중 상위 슬롯 %0d 오염 발생!", s);
                                        tc12_pass = 0;
                                    end
                                end
                                @(posedge clk);
                                #1;
                            end
                        end

                        begin : inference_driver
                            bit core_pass;
                            run_and_verify("TC 12 Stale Isolation & Inference", 0, core_pass);
                            if (!core_pass) tc12_pass = 0;
                        end
                    join
                end

                begin : timeout_watchdog
                    repeat(1000) @(posedge clk);
                    $error("[FAIL] TC 12: 시뮬레이션 타임아웃!");
                    timeout_occurred = 1;
                    tc12_pass = 0;
                end
            join_any
            disable fork;

            if (tc12_pass && !timeout_occurred) begin
                $display("[PASS] TC 12: Shared Buffer Stale Isolation & Cross-talk Integrity Confirmed");
                pass_cnt++;
            end else begin
                fail_cnt++;
            end
        end

        // =============================================================
        // 최종 결과 요약 리포트 (총 12개 시나리오)
        // =============================================================
        #(CLK_PERIOD * 10);
        $display("\n============================================================");
        $display("   SIMULATION VERIFICATION COMPLETE REPORT                  ");
        $display("============================================================");
        $display("   TOTAL SCENARIOS : %0d (Part 1: 10, Part 2: 2)", test_cnt);
        $display("   PASSED          : %0d", pass_cnt);
        $display("   FAILED          : %0d", fail_cnt);
        if (fail_cnt == 0 && test_cnt == 12)
            $display("   >>> [FINAL VERDICT: ALL 12 TESTS PASSED PERFECTLY] <<<");
        else
            $display("   >>> [FINAL VERDICT: VERIFICATION FAILED - REVIEW LOG] <<<");
        $display("============================================================\n");

        $finish;
    end

endmodule
