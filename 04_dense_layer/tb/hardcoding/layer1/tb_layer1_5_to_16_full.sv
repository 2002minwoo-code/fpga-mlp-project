`timescale 1ns / 1ps

module tb_layer1_5_to_16_full;

    parameter int FEATURE_W = 8;
    parameter int WEIGHT_W  = 8;
    parameter int BIAS_W    = 32;
    parameter int ACC_W     = 32;
    parameter int N_NEURON  = 16;
    parameter int N_MAX     = 16;
    parameter int N_MAC     = 8;

    // Requantizer Q-format (필요시 조정)
    parameter int IN_FRAC   = 8;
    parameter int OUT_FRAC  = 4;

    parameter int WMEM_DATA_W = N_MAC * WEIGHT_W; // 64-bit
    parameter int BMEM_DATA_W = N_MAC * BIAS_W;   // 256-bit

    // dense_layer와 동일한 공식으로 주소 폭 계산 (이전 mismatch 재발 방지)
    localparam int N_GROUP     = (N_NEURON + N_MAC - 1) / N_MAC;              // 2
    parameter  int WMEM_ADDR_W = $clog2(N_GROUP * N_MAX);                     // 5
    parameter  int BMEM_ADDR_W = (N_GROUP > 1) ? $clog2(N_GROUP) : 1;         // 1

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

    // Layer Outputs
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

    // 3. Dense Layer (5 -> 16)
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON),   .N_MAX(N_MAX),       .ACC_W(ACC_W), .N_MAC(N_MAC),
        .WMEM_ADDR_W(WMEM_ADDR_W), .BMEM_ADDR_W(BMEM_ADDR_W)
    ) u_dense_layer1 (
        .i_clk(clk), .i_rstn(rst_n), .i_start(start),
        .i_num_neurons(N_NEURON), .i_num_inputs(5),
        .i_feature(feat_buff),
        .o_wmem_addr(wmem_addr), .i_wmem_data(wmem_data),
        .o_bmem_addr(bmem_addr), .i_bmem_data(bmem_data),
        .o_result(dense_out), .o_busy(busy), .o_done(done)
    );

    // 4. ReLU (실제 모듈 인스턴스화)
    relu_layer #(
        .IN_W(ACC_W),
        .N_NEURON(N_NEURON)
    ) u_relu (
        .in_data (dense_out),
        .out_data(relu_out)
    );

    // 5. Requantizer (실제 모듈 인스턴스화)
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

    // ------------------------------------------------------------
    // 기대값 (bmem_layer1.mem의 실제 bias 반영, 손검산으로 확인 완료)
    //   그룹0(뉴런0~7)  : bias=0
    //   그룹1(뉴런8~15) : bias(g'=0..7) = 0,0,0,1,2,3,4,5  (packed 순서상 역순 매핑)
    // ------------------------------------------------------------
    int expected_dense [0:N_NEURON-1] = '{
        140, 145, 150, 155, 160, 165, 170, 175,
        175, 170, 165, 161, 157, 153, 149, 145
    };
    int expected_req [0:N_NEURON-1] = '{
        9, 9, 9, 10, 10, 10, 11, 11,
        11, 11, 10, 10, 10, 10, 9, 9
    };

    // Test Scenario & Raw File Output
    int file_fd;
    int mismatch_cnt;
    initial begin
        clk   = 0;
        rst_n = 0;
        start = 0;

        // 입력 피처 초기화
        feat_buff[0] = 8'd5;
        feat_buff[1] = 8'd10;
        feat_buff[2] = 8'd15;
        feat_buff[3] = 8'd20;
        feat_buff[4] = 8'd25;
        for (int k = 5; k < N_MAX; k++) feat_buff[k] = 0;

        #20 rst_n = 1;
        #10 start = 1;
        #10 start = 0;

        @(posedge done);
        #10;

        // ---- 콘솔에 실측값 vs 기대값 비교 출력 ----
        $display("");
        $display("[TB1] ===== dense_out (raw) : actual vs expected =====");
        mismatch_cnt = 0;
        for (int k = 0; k < N_NEURON; k++) begin
            if (dense_out[k] !== expected_dense[k]) begin
                $display("  neuron[%0d] actual=%0d  expected=%0d  <-- MISMATCH", k, dense_out[k], expected_dense[k]);
                mismatch_cnt++;
            end else begin
                $display("  neuron[%0d] actual=%0d  expected=%0d  OK", k, dense_out[k], expected_dense[k]);
            end
        end

        $display("");
        $display("[TB1] ===== req_out (ReLU+Requant) : actual vs expected =====");
        for (int k = 0; k < N_NEURON; k++) begin
            if (req_out[k] !== expected_req[k]) begin
                $display("  neuron[%0d] actual=%0d  expected=%0d  <-- MISMATCH", k, req_out[k], expected_req[k]);
                mismatch_cnt++;
            end else begin
                $display("  neuron[%0d] actual=%0d  expected=%0d  OK", k, req_out[k], expected_req[k]);
            end
        end

        $display("");
        if (mismatch_cnt == 0)
            $display("[TB1] ===== ALL MATCH (%0d/%0d) - PASS =====", 2*N_NEURON, 2*N_NEURON);
        else
            $display("[TB1] ===== %0d MISMATCH FOUND - FAIL =====", mismatch_cnt);
        $display("");

        // Raw 파일 저장 (ReLU + Requantize까지 거친 최종 8-bit 결과)
        // 절대경로 고정: 매번 xsim 작업 디렉토리를 뒤질 필요 없이 여기서 바로 확인
        file_fd = $fopen("C:/Sim_out/layer1_output.bin", "wb");
        if (file_fd) begin
            for (int k = 0; k < N_NEURON; k++) begin
                $fwrite(file_fd, "%c", req_out[k]);
            end
            $fclose(file_fd);
            $display("[TB 1] Layer 1 Output (ReLU+Requant) saved to C:/Sim_out/layer1_output.bin");
        end else begin
            $display("[TB 1][ERROR] Failed to open output file - check that C:/Sim_out exists");
        end

        $finish;
    end

endmodule
