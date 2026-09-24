`timescale 1ns / 1ps

// =============================================================
// tb_layer2_golden_verify.sv
//
// Verification Layer2 : layer_buffer -> Dense Layer2(16->8) -> Requantize
//
// =============================================================
module tb_layer2_golden_verify;

    parameter int FEATURE_W = 8;
    parameter int WEIGHT_W  = 8;
    parameter int BIAS_W    = 32;
    parameter int ACC_W     = 32;
    parameter int N_NEURON  = 8;    // Layer2: 16 -> 8
    parameter int N_MAX     = 16;
    parameter int N_MAC     = 8;

    parameter int IN_FRAC  = 8;
    parameter int OUT_FRAC = 4;

    parameter int WMEM_DATA_W = N_MAC * WEIGHT_W; // 64-bit
    parameter int BMEM_DATA_W = N_MAC * BIAS_W;   // 256-bit

    localparam int N_GROUP     = (N_NEURON + N_MAC - 1) / N_MAC;          // 1
    parameter  int WMEM_ADDR_W = $clog2(N_GROUP * N_MAX);                 // 4
    parameter  int BMEM_ADDR_W = (N_GROUP > 1) ? $clog2(N_GROUP) : 1;     // 1
    localparam int WMEM_DEPTH  = N_GROUP * N_MAX;                         // 16

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

    // 16개 테스트 입력 (엣지케이스: 음수 포함) - golden 계산에도 그대로 사용
    logic signed [FEATURE_W-1:0] test_feat [0:N_MAX-1] = '{
        8'sd5, -8'sd3, 8'sd8, -8'sd6, 8'sd2, -8'sd9, 8'sd4, -8'sd1,
        8'sd7, -8'sd5, 8'sd3, -8'sd8, 8'sd6, -8'sd2, 8'sd9, -8'sd4
    };

    // BRAM Signals
    logic [WMEM_ADDR_W-1:0] wmem_addr;
    logic [WMEM_DATA_W-1:0] wmem_data;
    logic [BMEM_ADDR_W-1:0] bmem_addr;
    logic [BMEM_DATA_W-1:0] bmem_data;

    // DUT Outputs
    logic signed [ACC_W-1:0]     dense_out [0:N_NEURON-1];
    logic signed [FEATURE_W-1:0] req_out   [0:N_NEURON-1];

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

    // 1. Weight Memory (Layer 2)
    weight_memory #(
        .DATA_W(WMEM_DATA_W), .ADDR_W(WMEM_ADDR_W),
        .INIT_FILE("wmem_layer2.mem")
    ) u_wmem (
        .i_clk(clk), .i_addr(wmem_addr), .o_data(wmem_data)
    );

    // 2. Bias Memory (Layer 2)
    bias_memory #(
        .DATA_W(BMEM_DATA_W), .ADDR_W(BMEM_ADDR_W),
        .INIT_FILE("bmem_layer2.mem")
    ) u_bmem (
        .i_clk(clk), .i_addr(bmem_addr), .o_data(bmem_data)
    );

    // 3. Dense Layer (16 -> 8)  [DUT]
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON),   .N_MAX(N_MAX),       .ACC_W(ACC_W), .N_MAC(N_MAC),
        .WMEM_ADDR_W(WMEM_ADDR_W), .BMEM_ADDR_W(BMEM_ADDR_W)
    ) u_dense_layer2 (
        .i_clk(clk), .i_rstn(rst_n), .i_start(start),
        .i_num_neurons(N_NEURON), .i_num_inputs(N_MAX),
        .i_feature(buf_out),
        .o_wmem_addr(wmem_addr), .i_wmem_data(wmem_data),
        .o_bmem_addr(bmem_addr), .i_bmem_data(bmem_data),
        .o_result(dense_out), .o_busy(busy), .o_done(done)
    );

    // 4. Requantizer  [DUT]  (ReLU 없음)
    requantize_layer #(
        .IN_W    (ACC_W),
        .IN_FRAC (IN_FRAC),
        .OUT_W   (FEATURE_W),
        .OUT_FRAC(OUT_FRAC),
        .N_NEURON(N_NEURON)
    ) u_requant (
        .in_data (dense_out),
        .out_data(req_out)
    );

    // =========================================================
    // Golden Reference Model
    // =========================================================
    logic [WMEM_DATA_W-1:0] golden_wmem [0:WMEM_DEPTH-1];
    logic [BMEM_DATA_W-1:0] golden_bmem [0:N_GROUP-1];

    int golden_dense [0:N_NEURON-1];
    int golden_req   [0:N_NEURON-1];

    initial begin
        $readmemh("wmem_layer2.mem", golden_wmem);
        $readmemh("bmem_layer2.mem", golden_bmem);
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

    // dense -> Requantize (ReLU 없음)
    task automatic compute_golden();
        int sum;
        int shift, rounded, shifted;
        int MAXV, MINV;

        shift = IN_FRAC - OUT_FRAC;
        MAXV  = (1 << (FEATURE_W-1)) - 1;   //  127
        MINV  = -(1 << (FEATURE_W-1));      // -128

        for (int n = 0; n < N_NEURON; n++) begin
            sum = get_bias(n);
            for (int k = 0; k < N_MAX; k++)
                sum += test_feat[k] * get_weight(n, k);
            golden_dense[n] = sum;

            // ReLU 없음 - dense_out을 바로 requantize
            if (shift > 0) begin
                rounded = golden_dense[n] + (1 << (shift-1));
                shifted = rounded >>> shift;   // arithmetic shift = floor, 음수도 동일하게 처리
            end else begin
                shifted = golden_dense[n];
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
        clk       = 0;
        rst_n     = 0;
        start     = 0;
        buf_wr_en = 0;
        buf_wr_addr = '0;
        buf_wr_data = '0;

        #20 rst_n = 1;
        #10;

        // layer_buffer에 16개 테스트 값 순차 write
        for (int k = 0; k < N_MAX; k++) begin
            @(posedge clk);
            buf_wr_en   = 1;
            buf_wr_addr = k[$clog2(N_MAX)-1:0];
            buf_wr_data = test_feat[k];
        end
        @(posedge clk);
        buf_wr_en = 0;

        #1;
        $display("[TB2-GOLDEN] layer_buffer contents:");
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
        $display("[TB2-GOLDEN] ===== dense_out : DUT vs GOLDEN =====");
        for (int n = 0; n < N_NEURON; n++) begin
            if (dense_out[n] !== golden_dense[n]) begin
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  <-- MISMATCH", n, dense_out[n], golden_dense[n]);
                mismatch_cnt++;
            end else
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  OK", n, dense_out[n], golden_dense[n]);
        end

        $display("");
        $display("[TB2-GOLDEN] ===== req_out : DUT vs GOLDEN =====");
        for (int n = 0; n < N_NEURON; n++) begin
            if (req_out[n] !== golden_req[n]) begin
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  <-- MISMATCH", n, req_out[n], golden_req[n]);
                mismatch_cnt++;
            end else
                $display("  neuron[%0d] DUT=%0d  GOLDEN=%0d  OK", n, req_out[n], golden_req[n]);
        end

        $display("");
        if (mismatch_cnt == 0)
            $display("[TB2-GOLDEN] ===== ALL MATCH (%0d checks) - PASS =====", 2*N_NEURON);
        else
            $display("[TB2-GOLDEN] ===== %0d MISMATCH FOUND - FAIL =====", mismatch_cnt);
        $display("");

        file_fd = $fopen("C:/Sim_out/layer2_output.bin", "wb");
        if (file_fd) begin
            for (int n = 0; n < N_NEURON; n++) $fwrite(file_fd, "%c", req_out[n]);
            $fclose(file_fd);
            $display("[TB2-GOLDEN] saved to C:/Sim_out/layer2_output.bin");
        end else begin
            $display("[TB2-GOLDEN][ERROR] Failed to open output file - check that C:/Sim_out exists");
        end

        $finish;
    end

endmodule
