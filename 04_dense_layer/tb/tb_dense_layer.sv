// =============================================================
// tb_dense_layer_bram.sv (계층 구조 검증용 테스트벤치)
// =============================================================
`timescale 1ns / 1ps

module tb_dense_layer_bram;

    localparam int FEATURE_W = 8;
    localparam int WEIGHT_W  = 8;
    localparam int BIAS_W    = 32;
    localparam int N_NEURON  = 16;
    localparam int N_MAX     = 16;
    localparam int ACC_W     = 32;
    localparam int N_MAC     = 8;

    localparam int WMEM_DATA_W = N_MAC * WEIGHT_W;
    localparam int BMEM_DATA_W = N_MAC * BIAS_W;
    localparam int WMEM_ADDR_W = $clog2((N_NEURON/N_MAC) * N_MAX);
    localparam int BMEM_ADDR_W = (N_NEURON/N_MAC > 1) ? $clog2(N_NEURON/N_MAC) : 1;

    logic clk;
    logic rst_n;
    logic                         i_dl_start;
    logic [$clog2(N_NEURON+1)-1:0] i_num_neurons;
    logic [$clog2(N_MAX+1)-1:0]    i_num_inputs;

    logic signed [FEATURE_W-1:0] i_dl_feature [0:N_MAX-1];

    logic [WMEM_ADDR_W-1:0] o_wmem_addr;
    logic [WMEM_DATA_W-1:0] i_wmem_rdata;

    logic [BMEM_ADDR_W-1:0] o_bmem_addr;
    logic [BMEM_DATA_W-1:0] i_bmem_rdata;

    logic signed [ACC_W-1:0] o_dl_result [0:N_NEURON-1];
    logic                    o_dl_busy;
    logic                    o_dl_done;

    // -------------------------------------------------------------
    // BRAM 시뮬레이션 모델 (1-Clock Read Latency)
    // -------------------------------------------------------------
    logic [WMEM_DATA_W-1:0] wmem [0:(1<<WMEM_ADDR_W)-1];
    logic [BMEM_DATA_W-1:0] bmem [0:(1<<BMEM_ADDR_W)-1];

    always_ff @(posedge clk) begin
        i_wmem_rdata <= wmem[o_wmem_addr];
        i_bmem_rdata <= bmem[o_bmem_addr];
    end

    // DUT 인스턴스화 (Top)
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON),   .N_MAX(N_MAX),       .ACC_W(ACC_W), .N_MAC(N_MAC)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_dl_start   (i_dl_start),
        .i_num_neurons(i_num_neurons),
        .i_num_inputs (i_num_inputs),
        .i_dl_feature (i_dl_feature),
        .o_wmem_addr  (o_wmem_addr),
        .i_wmem_rdata (i_wmem_rdata),
        .o_bmem_addr  (o_bmem_addr),
        .i_bmem_rdata (i_bmem_rdata),
        .o_dl_result  (o_dl_result),
        .o_dl_busy    (o_dl_busy),
        .o_dl_done    (o_dl_done)
    );

    // 100MHz 클록
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // -------------------------------------------------------------
    // Golden Reference 및 검증 Task
    // -------------------------------------------------------------
    task automatic run_layer_test(
        input int num_inputs,
        input int num_neurons,
        input string layer_name
    );
        logic signed [FEATURE_W-1:0] raw_feat [0:N_MAX-1];
        logic signed [WEIGHT_W-1:0]  raw_wgt  [0:N_NEURON-1][0:N_MAX-1];
        logic signed [BIAS_W-1:0]    raw_bias [0:N_NEURON-1];
        logic signed [ACC_W-1:0]     golden_res [0:N_NEURON-1];

        int pass_cnt = 0;
        int num_groups = (num_neurons + N_MAC - 1) / N_MAC;

        // 초기화
        for (int i = 0; i < (1<<WMEM_ADDR_W); i++) wmem[i] = '0;
        for (int i = 0; i < (1<<BMEM_ADDR_W); i++) bmem[i] = '0;
        for (int i = 0; i < N_MAX; i++)            i_dl_feature[i] = '0;

        // Random 데이터 생성
        for (int i = 0; i < num_inputs; i++) begin
            raw_feat[i] = $signed($urandom_range(0, 255)) - 128;
            i_dl_feature[i] = raw_feat[i];
        end

        for (int n = 0; n < num_neurons; n++) begin
            raw_bias[n] = $signed($urandom_range(0, 2000)) - 1000;
            for (int i = 0; i < num_inputs; i++) begin
                raw_wgt[n][i] = $signed($urandom_range(0, 255)) - 128;
            end
        end

        // Golden 소프트웨어 결과 계산
        for (int n = 0; n < num_neurons; n++) begin
            logic signed [ACC_W-1:0] sum;
            sum = raw_bias[n];
            for (int i = 0; i < num_inputs; i++) begin
                sum = sum + (raw_feat[i] * raw_wgt[n][i]);
            end
            golden_res[n] = sum;
        end

        // BRAM 패킹
        for (int g_idx = 0; g_idx < num_groups; g_idx++) begin
            logic [BMEM_DATA_W-1:0] b_packet = '0;
            for (int g = 0; g < N_MAC; g++) begin
                int neu_idx = g_idx * N_MAC + g;
                if (neu_idx < num_neurons)
                    b_packet[g*BIAS_W +: BIAS_W] = raw_bias[neu_idx];
            end
            bmem[g_idx] = b_packet;
        end

        for (int g_idx = 0; g_idx < num_groups; g_idx++) begin
            for (int f_idx = 0; f_idx < num_inputs; f_idx++) begin
                logic [WMEM_DATA_W-1:0] w_packet = '0;
                for (int g = 0; g < N_MAC; g++) begin
                    int neu_idx = g_idx * N_MAC + g;
                    if (neu_idx < num_neurons)
                        w_packet[g*WEIGHT_W +: WEIGHT_W] = raw_wgt[neu_idx][f_idx];
                end
                wmem[(g_idx * num_inputs) + f_idx] = w_packet;
            end
        end

        // RTL 실행
        i_num_inputs  = num_inputs;
        i_num_neurons = num_neurons;

        @(posedge clk); #1;
        i_dl_start = 1;
        @(posedge clk); #1;
        i_dl_start = 0;

        $display("==================================================");
        $display(" TEST: %s (Inputs: %0d -> Neurons: %0d)", layer_name, num_inputs, num_neurons);
        $display("==================================================");

        wait(o_dl_done == 1'b1);
        @(posedge clk);

        // 하위 mac_unit 출력 및 최종 결과 검증
        for (int n = 0; n < num_neurons; n++) begin
            if (o_dl_result[n] === golden_res[n]) begin
                $display("  [PASS] Neuron %2d : RTL = %8d | Golden = %8d", n, o_dl_result[n], golden_res[n]);
                pass_cnt++;
            end else begin
                $display("  [FAIL] Neuron %2d : RTL = %8d | Golden = %8d", n, o_dl_result[n], golden_res[n]);
            end
        end

        if (pass_cnt == num_neurons)
            $display(">> %s SUCCESS!\n", layer_name);
        else
            $display(">> %s FAILED!\n", layer_name);

        #50;
    endtask

    // 메인 시뮬레이션
    initial begin
        rst_n = 0;
        i_dl_start = 0;
        i_num_inputs = 0;
        i_num_neurons = 0;
        #20;
        rst_n = 1;
        #20;

        run_layer_test(5,  16, "Layer 1 (5 -> 16)");
        run_layer_test(16, 8,  "Layer 2 (16 -> 8)");
        run_layer_test(8,  1,  "Layer 3 (8 -> 1)");

        $display("==================================================");
        $display("   ALL HIERARCHICAL TESTS COMPLETED");
        $display("==================================================");
        $finish;
    end

endmodule
