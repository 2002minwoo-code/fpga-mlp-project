`timescale 1ns / 1ps

// =============================================================
// tb_layer1_golden_verify.sv
//
// Verification Layer1 : Feature Buffer -> Dense Layer1(5->16) -> ReLU -> Requantize
//
// =============================================================
module tb_layer1_golden_verify;

    parameter int FEATURE_W  = 8;
    parameter int WEIGHT_W   = 8;
    parameter int BIAS_W     = 32;
    parameter int ACC_W      = 32;
    parameter int N_NEURON   = 16;
    parameter int N_MAX      = 16;
    parameter int N_MAC      = 8;
    parameter int NUM_INPUTS = 5;     // 실제 유효 입력 개수 (5 -> 16 레이어)

    // Requantizer Q-format
    parameter int IN_FRAC  = 8;
    parameter int OUT_FRAC = 4;

    parameter int WMEM_DATA_W = N_MAC * WEIGHT_W; // 64-bit
    parameter int BMEM_DATA_W = N_MAC * BIAS_W;   // 256-bit

    localparam int N_GROUP     = (N_NEURON + N_MAC - 1) / N_MAC;          // 2
    parameter  int WMEM_ADDR_W = $clog2(N_GROUP * N_MAX);                 // 5
    parameter  int BMEM_ADDR_W = (N_GROUP > 1) ? $clog2(N_GROUP) : 1;     // 1
    localparam int WMEM_DEPTH  = N_GROUP * N_MAX;                         // 32

    logic clk;
    logic rst_n;
    logic start;
    logic done;
    logic busy;

    // Feature Buffer (입력 5개 저장용)
    logic signed [FEATURE_W-1:0] feat_buff [0:N_MAX-1];

    // BRAM Signals
    logic [WMEM_ADDR_W-1:0] wmem_addr;
    logic [WMEM_DATA_W-1:0] wmem_data;
    logic [BMEM_ADDR_W-1:0] bmem_addr;
    logic [BMEM_DATA_W-1:0] bmem_data;

    // DUT Outputs
    logic signed [ACC_W-1:0]     dense_out [0:N_NEURON-1];
    logic signed [ACC_W-1:0]     relu_out  [0:N_NEURON-1];
    logic signed [FEATURE_W-1:0] req_out   [0:N_NEURON-1];

    // Clock Generation
    always #5 clk = ~clk;

    // 1. Weight Memory
    weight_memory #(
        .DATA_W(WMEM_DATA_W), .ADDR_W(WMEM_ADDR_W),
        .INIT_FILE("wmem_layer1.mem")
    ) u_wmem (
        .i_clk(clk), .i_addr(wmem_addr), .o_data(wmem_data)
    );

    // 2. Bias Memory
    bias_memory #(
        .DATA_W(BMEM_DATA_W), .ADDR_W(BMEM_ADDR_W),
        .INIT_FILE("bmem_layer1.mem")
    ) u_bmem (
        .i_clk(clk), .i_addr(bmem_addr), .o_data(bmem_data)
    );

    // 3. Dense Layer (5 -> 16)  [DUT]
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON),   .N_MAX(N_MAX),       .ACC_W(ACC_W), .N_MAC(N_MAC),
        .WMEM_ADDR_W(WMEM_ADDR_W), .BMEM_ADDR_W(BMEM_ADDR_W)
    ) u_dense_layer1 (
        .i_clk(clk), .i_rstn(rst_n), .i_start(start),
        .i_num_neurons(N_NEURON), .i_num_inputs(NUM_INPUTS),
        .i_feature(feat_buff),
        .o_wmem_addr(wmem_addr), .i_wmem_data(wmem_data),
        .o_bmem_addr(bmem_addr), .i_bmem_data(bmem_data),
        .o_result(dense_out), .o_busy(busy), .o_done(done)
    );

    // 4. ReLU  [DUT]
    relu_layer #(
        .IN_W(ACC_W),
        .N_NEURON(N_NEURON)
    ) u_relu (
        .in_data (dense_out),
        .out_data(relu_out)
    );

    // 5. Requantizer  [DUT]
    requantize_layer #(
        .IN_W    (ACC_W),
        .IN_FRAC (IN_FRAC),
        .OUT_W   (FEATURE_W),
        .OUT_FRAC(OUT_FRAC),
        .N_NEURON(N_NEURON)
    ) u_requant (
        .in_data (relu_out),
        .out_data(req_out)
    );

    // =========================================================
    // Golden Reference Model (순수 소프트웨어 재계산, DUT와 독립)
    // =========================================================
    logic [WMEM_DATA_W-1:0] golden_wmem [0:WMEM_DEPTH-1];
    logic [BMEM_DATA_W-1:0] golden_bmem [0:N_GROUP-1];

    int golden_dense [0:N_NEURON-1];
    int golden_relu  [0:N_NEURON-1];
    int golden_req   [0:N_NEURON-1];

    initial begin
        // DUT가 읽는 것과 완전히 동일한 파일을 tb가 별도로 읽는다.
        $readmemh("wmem_layer1.mem", golden_wmem);
        $readmemh("bmem_layer1.mem", golden_bmem);
    end

    // dense_layer의 패킹 규칙과 동일하게 뉴런별 weight/bias를 뽑아낸다.
    //   weight: golden_wmem[group*N_MAX + k] 의 [g_in_group*WEIGHT_W +: WEIGHT_W]
    //   bias  : golden_bmem[group]           의 [g_in_group*BIAS_W   +: BIAS_W]
    function automatic int signed get_weight(int neuron, int k);
        int group, g_in_group;
        group      = neuron / N_MAC;
        g_in_group = neuron % N_MAC;
        return $signed(golden_wmem[group*N_MAX + k][g_in_group*WEIGHT_W +: WEIGHT_W]);
    endfunction

    function automatic int signed get_bias(int neuron);
        int group, g_in_group;
        group      = neuron / N_MAC;
        g_in_group = neuron % N_MAC;
        return $signed(golden_bmem[group][g_in_group*BIAS_W +: BIAS_W]);
    endfunction

    // dense -> ReLU -> Requantize 를 알고리즘 그대로 재계산
    task automatic compute_golden();
        int sum;
        int shift, rounded, shifted;
        int MAXV, MINV;

        shift = IN_FRAC - OUT_FRAC;
        MAXV  = (1 << (FEATURE_W-1)) - 1;   //  127
        MINV  = -(1 << (FEATURE_W-1));      // -128

        for (int n = 0; n < N_NEURON; n++) begin
            // ---- Dense (MAC) ----
            sum = get_bias(n);
            for (int k = 0; k < NUM_INPUTS; k++)
                sum += feat_buff[k] * get_weight(n, k);
            golden_dense[n] = sum;

            // ---- ReLU ----
            golden_relu[n] = (golden_dense[n] < 0) ? 0 : golden_dense[n];

            // ---- Requantize (round-half-up & saturate) ----
            if (shift > 0) begin
                rounded = golden_relu[n] + (1 << (shift-1));
                shifted = rounded >>> shift;
            end else begin
                shifted = golden_relu[n];
            end

            if (shifted > MAXV)      golden_req[n] = MAXV;
            else if (shifted < MINV) golden_req[n] = MINV;
            else                     golden_req[n] = shifted;
        end
    endtask

    // =========================================================
    // Test Scenario
    // =========================================================
    int file_fd;
    int mismatch_cnt;

    initial begin
        clk   = 0;
        rst_n = 0;
        start = 0;

        // 입력 피처 초기화 (엣지케이스: 음수 포함)
        feat_buff[0] = -8'sd5;
        feat_buff[1] = 8'sd10;
        feat_buff[2] = -8'sd15;
        feat_buff[3] = 8'sd20;
        feat_buff[4] = 8'sd25;
        for (int k = 5; k < N_MAX; k++) feat_buff[k] = 0;

        #20 rst_n = 1;
        #10 start = 1;
        #10 start = 0;

        @(posedge done);
        #10;

        // DUT가 다 끝난 시점에 골든 모델도 같은 입력으로 계산
        compute_golden();

        // ---- DUT vs GOLDEN 비교 출력 ----
        mismatch_cnt = 0;

        $display("");
        $display("[TB1-GOLDEN] ===== dense_out : DUT vs GOLDEN =====");
        for (int n = 0; n < N_NEURON; n++) begin
            if (dense_out[n] !== golden_dense[n]) begin
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  <-- MISMATCH", n, dense_out[n], golden_dense[n]);
                mismatch_cnt++;
            end else
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  OK", n, dense_out[n], golden_dense[n]);
        end

        $display("");
        $display("[TB1-GOLDEN] ===== relu_out : DUT vs GOLDEN =====");
        for (int n = 0; n < N_NEURON; n++) begin
            if (relu_out[n] !== golden_relu[n]) begin
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  <-- MISMATCH", n, relu_out[n], golden_relu[n]);
                mismatch_cnt++;
            end else
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  OK", n, relu_out[n], golden_relu[n]);
        end

        $display("");
        $display("[TB1-GOLDEN] ===== req_out : DUT vs GOLDEN =====");
        for (int n = 0; n < N_NEURON; n++) begin
            if (req_out[n] !== golden_req[n]) begin
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  <-- MISMATCH", n, req_out[n], golden_req[n]);
                mismatch_cnt++;
            end else
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  OK", n, req_out[n], golden_req[n]);
        end

        $display("");
        if (mismatch_cnt == 0)
            $display("[TB1-GOLDEN] ===== ALL MATCH (%0d checks) - PASS =====", 3*N_NEURON);
        else
            $display("[TB1-GOLDEN] ===== %0d MISMATCH FOUND - FAIL =====", mismatch_cnt);
        $display("");

        // Raw 파일 저장 (ReLU + Requantize까지 거친 최종 8-bit 결과)
        file_fd = $fopen("C:/Sim_out/layer1_output.bin", "wb");
        if (file_fd) begin
            for (int k = 0; k < N_NEURON; k++) $fwrite(file_fd, "%c", req_out[k]);
            $fclose(file_fd);
            $display("[TB1-GOLDEN] Layer 1 Output saved to C:/Sim_out/layer1_output.bin");
        end else begin
            $display("[TB1-GOLDEN][ERROR] Failed to open output file - check that C:/Sim_out exists");
        end

        $finish;
    end

endmodule
