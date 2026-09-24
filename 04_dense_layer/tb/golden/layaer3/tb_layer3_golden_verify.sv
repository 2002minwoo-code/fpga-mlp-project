`timescale 1ns / 1ps

// =============================================================
// tb_layer3_golden_verify.sv
//
// Verification Output Layer : layer_buffer -> Dense Layer3(8->1)
//
// =============================================================
module tb_layer3_golden_verify;

    parameter int FEATURE_W = 8;
    parameter int WEIGHT_W  = 8;
    parameter int BIAS_W    = 32;
    parameter int ACC_W     = 32;
    parameter int N_NEURON  = 1;   // Output Layer: 8 -> 1
    parameter int N_MAX     = 8;
    parameter int N_MAC     = 8;

    parameter int WMEM_DATA_W = N_MAC * WEIGHT_W; // 64-bit
    parameter int BMEM_DATA_W = N_MAC * BIAS_W;   // 256-bit

    localparam int N_GROUP     = (N_NEURON + N_MAC - 1) / N_MAC;          // 1
    parameter  int WMEM_ADDR_W = $clog2(N_GROUP * N_MAX);                 // 3
    parameter  int BMEM_ADDR_W = (N_GROUP > 1) ? $clog2(N_GROUP) : 1;     // 1
    localparam int WMEM_DEPTH  = N_GROUP * N_MAX;                         // 8

    logic clk;
    logic rst_n;
    logic start;
    logic done;
    logic busy;

    // ---- layer_buffer write-side control ----
    logic                        buf_wr_en;
    logic [$clog2(N_MAX)-1:0]    buf_wr_addr;
    logic signed [FEATURE_W-1:0] buf_wr_data;
    logic signed [FEATURE_W-1:0] buf_out [0:N_MAX-1];

    // 8개 테스트 입력 (엣지케이스: 음수 포함) - golden 계산에도 그대로 사용
    logic signed [FEATURE_W-1:0] test_feat [0:N_MAX-1] = '{
        8'sd12, -8'sd7, 8'sd20, -8'sd15, 8'sd5, -8'sd3, 8'sd18, -8'sd9
    };

    // BRAM Signals
    logic [WMEM_ADDR_W-1:0] wmem_addr;
    logic [WMEM_DATA_W-1:0] wmem_data;
    logic [BMEM_ADDR_W-1:0] bmem_addr;
    logic [BMEM_DATA_W-1:0] bmem_data;

    // DUT Output (raw, no ReLU/Requant)
    logic signed [ACC_W-1:0] dense_out [0:N_NEURON-1];

    // Clock Generation
    always #5 clk = ~clk;

    // 0. Feature Buffer
    layer_buffer #(
        .DATA_W(FEATURE_W),
        .DEPTH (N_MAX)
    ) u_feat_buf (
        .i_clk    (clk),
        .i_rstn   (rst_n),
        .i_wr_en  (buf_wr_en),
        .i_wr_addr(buf_wr_addr),
        .i_wr_data(buf_wr_data),
        .o_data   (buf_out)
    );

    // 1. Weight Memory (Output Layer)
    weight_memory #(
        .DATA_W(WMEM_DATA_W), .ADDR_W(WMEM_ADDR_W),
        .INIT_FILE("wmem_layer3.mem")
    ) u_wmem (
        .i_clk(clk), .i_addr(wmem_addr), .o_data(wmem_data)
    );

    // 2. Bias Memory (Output Layer)
    bias_memory #(
        .DATA_W(BMEM_DATA_W), .ADDR_W(BMEM_ADDR_W),
        .INIT_FILE("bmem_layer3.mem")
    ) u_bmem (
        .i_clk(clk), .i_addr(bmem_addr), .o_data(bmem_data)
    );

    // 3. Dense Layer (8 -> 1)  [DUT]
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON),   .N_MAX(N_MAX),       .ACC_W(ACC_W), .N_MAC(N_MAC),
        .WMEM_ADDR_W(WMEM_ADDR_W), .BMEM_ADDR_W(BMEM_ADDR_W)
    ) u_dense_layer3 (
        .i_clk(clk), .i_rstn(rst_n), .i_start(start),
        .i_num_neurons(N_NEURON), .i_num_inputs(N_MAX),
        .i_feature(buf_out),
        .o_wmem_addr(wmem_addr), .i_wmem_data(wmem_data),
        .o_bmem_addr(bmem_addr), .i_bmem_data(bmem_data),
        .o_result(dense_out), .o_busy(busy), .o_done(done)
    );

    // =========================================================
    // Golden Reference Model
    // =========================================================
    logic [WMEM_DATA_W-1:0] golden_wmem [0:WMEM_DEPTH-1];
    logic [BMEM_DATA_W-1:0] golden_bmem [0:N_GROUP-1];

    int golden_dense [0:N_NEURON-1];

    initial begin
        $readmemh("wmem_layer3.mem", golden_wmem);
        $readmemh("bmem_layer3.mem", golden_bmem);
    end

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

    task automatic compute_golden();
        int sum;
        for (int n = 0; n < N_NEURON; n++) begin
            sum = get_bias(n);
            for (int k = 0; k < N_MAX; k++)
                sum += test_feat[k] * get_weight(n, k);
            golden_dense[n] = sum;   // ReLU/Requantize 없음 - raw 값이 곧 최종 출력
        end
    endtask

    // =========================================================
    // Test Scenario
    // =========================================================
    int file_fd;
    int mismatch_cnt;

    initial begin
        clk       = 0;
        rst_n     = 0;
        start     = 0;
        buf_wr_en = 0;
        buf_wr_addr = '0;
        buf_wr_data = '0;

        #20 rst_n = 1;
        #10;

        for (int k = 0; k < N_MAX; k++) begin
            @(posedge clk);
            buf_wr_en   = 1;
            buf_wr_addr = k[$clog2(N_MAX)-1:0];
            buf_wr_data = test_feat[k];
        end
        @(posedge clk);
        buf_wr_en = 0;

        #1;
        $display("[TB3-GOLDEN] layer_buffer contents:");
        for (int k = 0; k < N_MAX; k++) $write("%0d ", buf_out[k]);
        $display("");

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        @(posedge done);
        #10;

        compute_golden();

        mismatch_cnt = 0;

        $display("");
        $display("[TB3-GOLDEN] ===== dense_out (Output Layer, raw) : DUT vs GOLDEN =====");
        if (dense_out[0] !== golden_dense[0]) begin
            $display("  DUT=%0d  GOLDEN=%0d  <-- MISMATCH", dense_out[0], golden_dense[0]);
            mismatch_cnt++;
        end else
            $display("  DUT=%0d  GOLDEN=%0d  OK", dense_out[0], golden_dense[0]);

        $display("");
        if (mismatch_cnt == 0)
            $display("[TB3-GOLDEN] ===== ALL MATCH - PASS =====");
        else
            $display("[TB3-GOLDEN] ===== %0d MISMATCH FOUND - FAIL =====", mismatch_cnt);
        $display("");

        file_fd = $fopen("C:/Sim_out/layer3_output.bin", "wb");
        if (file_fd) begin
            $fwrite(file_fd, "%c", dense_out[0][31:24]);
            $fwrite(file_fd, "%c", dense_out[0][23:16]);
            $fwrite(file_fd, "%c", dense_out[0][15:8]);
            $fwrite(file_fd, "%c", dense_out[0][7:0]);
            $fclose(file_fd);
            $display("[TB3-GOLDEN] saved to C:/Sim_out/layer3_output.bin");
        end else begin
            $display("[TB3-GOLDEN][ERROR] Failed to open output file - check that C:/Sim_out exists");
        end

        $finish;
    end

endmodule
