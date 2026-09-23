// =============================================================
// tb_dense_layer_bram.sv 
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

    // 변경된 포트명에 맞춘 신호 선언
    logic i_clk;
    logic i_rstn;
    logic                         i_start;
    logic [$clog2(N_NEURON+1)-1:0] i_num_neurons;
    logic [$clog2(N_MAX+1)-1:0]    i_num_inputs;

    logic signed [FEATURE_W-1:0] i_feature [0:N_MAX-1];

    logic [WMEM_ADDR_W-1:0] o_wmem_addr;
    logic [WMEM_DATA_W-1:0] i_wmem_data;

    logic [BMEM_ADDR_W-1:0] o_bmem_addr;
    logic [BMEM_DATA_W-1:0] i_bmem_data;

    logic signed [ACC_W-1:0] o_result [0:N_NEURON-1];
    logic                    o_busy;
    logic                    o_done;

    // -------------------------------------------------------------
    // BRAM 시뮬레이션 모델 (1-Clock Read Latency)
    // -------------------------------------------------------------
    logic [WMEM_DATA_W-1:0] wmem [0:(1<<WMEM_ADDR_W)-1];
    logic [BMEM_DATA_W-1:0] bmem [0:(1<<BMEM_ADDR_W)-1];

    always_ff @(posedge i_clk) begin
        i_wmem_data <= wmem[o_wmem_addr];
        i_bmem_data <= bmem[o_bmem_addr];
    end

    // DUT 인스턴스화 (Top)
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON),   .N_MAX(N_MAX),       .ACC_W(ACC_W), .N_MAC(N_MAC)
    ) dut (
        .i_clk        (i_clk),
        .i_rstn       (i_rstn),
        .i_start      (i_start),
        .i_num_neurons(i_num_neurons),
        .i_num_inputs (i_num_inputs),
        .i_feature    (i_feature),
        .o_wmem_addr  (o_wmem_addr),
        .i_wmem_data  (i_wmem_data),
        .o_bmem_addr  (o_bmem_addr),
        .i_bmem_data  (i_bmem_data),
        .o_result     (o_result),
        .o_busy       (o_busy),
        .o_done       (o_done)
    );

    // 100MHz 클록
    initial begin
        i_clk = 0;
        forever #5 i_clk = ~i_clk;
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
        for (int i = 0; i < N_MAX; i++)            i_feature[i] = '0;

        // Random 데이터 생성
        for (int i = 0; i < num_inputs; i++) begin
            raw_feat[i] = $signed($urandom_range(0, 255)) - 128;
            i_feature[i] = raw_feat[i];
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

        @(posedge i_clk); #1;
        i_start = 1;
        @(posedge i_clk); #1;
        i_start = 0;

        $display("==================================================");
        $display(" TEST: %s (Inputs: %0d -> Neurons: %0d)", layer_name, num_inputs, num_neurons);
        $display("==================================================");

        wait(o_done == 1'b1);
        @(posedge i_clk);

        // 하위 mac_unit 출력 및 최종 결과 검증
        for (int n = 0; n < num_neurons; n++) begin
            if (o_result[n] === golden_res[n]) begin
                $display("  [PASS] Neuron %2d : RTL = %8d | Golden = %8d", n, o_result[n], golden_res[n]);
                pass_cnt++;
            end else begin
                $display("  [FAIL] Neuron %2d : RTL = %8d | Golden = %8d", n, o_result[n], golden_res[n]);
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
        i_rstn = 0;
        i_start = 0;
        i_num_inputs = 0;
        i_num_neurons = 0;
        #20;
        i_rstn = 1;
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
