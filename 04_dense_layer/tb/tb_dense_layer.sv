`timescale 1ns / 1ps

// =============================================================
// tb_dense_layer_golden.sv
// Golden Reference Model 기반 dense_layer 무작위 난수 자동 검증 TB
// =============================================================
module tb_dense_layer_golden;

    localparam int FEATURE_W = 8;
    localparam int WEIGHT_W  = 8;
    localparam int BIAS_W    = 32;
    localparam int N_NEURON  = 16;
    localparam int N_MAX     = 16;
    localparam int ACC_W     = 32;
    localparam int N_MAC     = 8;

    logic clk;
    logic rst_n;
    logic                          i_dl_start;
    logic [$clog2(N_NEURON+1)-1:0] i_num_neurons;
    logic [$clog2(N_MAX+1)-1:0]    i_num_inputs;

    logic signed [FEATURE_W-1:0] i_dl_feature [0:N_MAX-1];
    logic signed [WEIGHT_W-1:0]  i_dl_weight  [0:N_NEURON-1][0:N_MAX-1];
    logic signed [BIAS_W-1:0]    i_dl_bias    [0:N_NEURON-1];

    logic signed [ACC_W-1:0] o_dl_result [0:N_NEURON-1];
    logic                    o_dl_busy;
    logic                    o_dl_done;

    // DUT 인스턴스화
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON), .N_MAX(N_MAX), .ACC_W(ACC_W), .N_MAC(N_MAC)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_dl_start   (i_dl_start),
        .i_num_neurons(i_num_neurons),
        .i_num_inputs (i_num_inputs),
        .i_dl_feature (i_dl_feature),
        .i_dl_weight  (i_dl_weight),
        .i_dl_bias    (i_dl_bias),
        .o_dl_result  (o_dl_result),
        .o_dl_busy    (o_dl_busy),
        .o_dl_done    (o_dl_done)
    );

    // 클록 생성 (100MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =============================================================
    // [Golden Reference Model Function]
    // =============================================================
    function automatic void calc_golden(
        input logic signed [FEATURE_W-1:0] feat [0:N_MAX-1],
        input logic signed [WEIGHT_W-1:0]  wgt  [0:N_NEURON-1][0:N_MAX-1],
        input logic signed [BIAS_W-1:0]    bias [0:N_NEURON-1],
        input int num_in,
        input int num_neu,
        output logic signed [ACC_W-1:0]    golden_res [0:N_NEURON-1]
    );
        for (int n = 0; n < N_NEURON; n++) golden_res[n] = '0;

        for (int n = 0; n < num_neu; n++) begin
            logic signed [ACC_W-1:0] acc_sum;
            acc_sum = bias[n];
            for (int i = 0; i < num_in; i++) begin
                acc_sum = acc_sum + (feat[i] * wgt[n][i]);
            end
            golden_res[n] = acc_sum;
        end
    endfunction

    // =============================================================
    // Golden Model 기반 무작위 자동 검증 Task
    // =============================================================
    task automatic run_golden_random_test(
        input int num_inputs,
        input int num_neurons,
        input int test_iterations,
        input string layer_name
    );
        logic signed [ACC_W-1:0] golden_result [0:N_NEURON-1];
        int total_errors = 0;

        $display("\n==================================================");
        $display(" GOLDEN MODEL TEST: %s (%0d Iterations)", layer_name, test_iterations);
        $display("  Configuration: Inputs = %0d, Neurons = %0d", num_inputs, num_neurons);
        $display("==================================================");

        for (int iter = 1; iter <= test_iterations; iter++) begin
            // 1. 입력 데이터 초기화
            for (int i = 0; i < N_MAX; i++) i_dl_feature[i] = '0;
            for (int n = 0; n < N_NEURON; n++) begin
                i_dl_bias[n] = '0;
                for (int i = 0; i < N_MAX; i++) i_dl_weight[n][i] = '0;
            end

            // 2. 난수 생성 (Signed 음수/양수 모두 포함)
            for (int i = 0; i < num_inputs; i++) begin
                i_dl_feature[i] = $signed($urandom_range(0, 255)) - 128; // -128 ~ 127
            end

            for (int n = 0; n < num_neurons; n++) begin
                i_dl_bias[n] = $signed($urandom_range(0, 2000)) - 1000;  // -1000 ~ 1000
                for (int i = 0; i < num_inputs; i++) begin
                    i_dl_weight[n][i] = $signed($urandom_range(0, 255)) - 128; // -128 ~ 127
                end
            end

            // 3. Golden Reference 미리 계산
            calc_golden(i_dl_feature, i_dl_weight, i_dl_bias, num_inputs, num_neurons, golden_result);

            // 4. RTL DUT 구동
            i_num_inputs  = num_inputs;
            i_num_neurons = num_neurons;

            @(posedge clk); #1;
            i_dl_start = 1;
            @(posedge clk); #1;
            i_dl_start = 0;

            // 5. RTL 완료 대기
            wait(o_dl_done == 1'b1);
            @(posedge clk);

            // 6. RTL 결과와 Golden 결과 1:1 비교
            for (int n = 0; n < num_neurons; n++) begin
                if (o_dl_result[n] !== golden_result[n]) begin
                    $display("  [MISMATCH!] Iter %0d | Neuron %2d | RTL: %0d != Golden: %0d",
                             iter, n, o_dl_result[n], golden_result[n]);
                    total_errors++;
                end
            end

            if (iter % 10 == 0) begin
                $display("  Progress: %0d / %0d tests passed...", iter, test_iterations);
            end
            #20;
        end

        if (total_errors == 0) begin
            $display(">> [%s] ALL %0d RANDOM TESTS PASSED PERFECTLY!\n", layer_name, test_iterations);
        end else begin
            $display(">> [%s] TEST FAILED WITH %0d MISMATCHES!\n", layer_name, total_errors);
        end
    endtask

    // =============================================================
    // 시뮬레이션 메인 루틴
    // =============================================================
    initial begin
        // 리셋 초기화
        rst_n = 0;
        i_dl_start = 0;
        i_num_inputs = 0;
        i_num_neurons = 0;
        #20;
        rst_n = 1;
        #20;

        // 3개 레이어 연속 테스트 (각 50회 무작위 난수 검증)
        run_golden_random_test(5,  16, 50, "Layer 1 (5 -> 16)");
        run_golden_random_test(16, 8,  50, "Layer 2 (16 -> 8)");
        run_golden_random_test(8,  1,  50, "Layer 3 (8 -> 1)");

        $display("==================================================");
        $display("   GOLDEN MODEL VERIFICATION COMPLETE!");
        $display("==================================================");
        $finish;
    end

endmodule

