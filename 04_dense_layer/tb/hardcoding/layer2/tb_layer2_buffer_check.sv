`timescale 1ns / 1ps

// =============================================================
// tb_layer2_buffer_check.sv
// layer_buffer -> dense_layer(16->8) -> requantize (ReLU 없음)
// =============================================================
module tb_layer2_buffer_check;

    parameter int FEATURE_W = 8;
    parameter int WEIGHT_W  = 8;
    parameter int BIAS_W    = 32;
    parameter int ACC_W     = 32;
    parameter int N_NEURON  = 8;   // Layer2: 16 -> 8
    parameter int N_MAX     = 16;
    parameter int N_MAC     = 8;

    parameter int IN_FRAC   = 8;
    parameter int OUT_FRAC  = 4;

    parameter int WMEM_DATA_W = N_MAC * WEIGHT_W; // 64-bit
    parameter int BMEM_DATA_W = N_MAC * BIAS_W;   // 256-bit

    localparam int N_GROUP     = (N_NEURON + N_MAC - 1) / N_MAC;          // 1
    parameter  int WMEM_ADDR_W = $clog2(N_GROUP * N_MAX);                 // 4
    parameter  int BMEM_ADDR_W = (N_GROUP > 1) ? $clog2(N_GROUP) : 1;     // 1

    logic clk;
    logic rst_n;
    logic start;
    logic done;
    logic busy;

    // ---- layer_buffer write-side control (tb가 직접 구동) ----
    logic                        buf_wr_en;
    logic [$clog2(N_MAX)-1:0]    buf_wr_addr;
    logic signed [FEATURE_W-1:0] buf_wr_data;
    logic signed [FEATURE_W-1:0] buf_out [0:N_MAX-1]; // layer_buffer의 o_data, dense_layer의 i_feature로 직결

    // BRAM Signals
    logic [WMEM_ADDR_W-1:0] wmem_addr;
    logic [WMEM_DATA_W-1:0] wmem_data;
    logic [BMEM_ADDR_W-1:0] bmem_addr;
    logic [BMEM_DATA_W-1:0] bmem_data;

    // Layer Outputs
    logic signed [ACC_W-1:0]     dense_out [0:N_NEURON-1];
    logic signed [FEATURE_W-1:0] req_out   [0:N_NEURON-1];

    // Clock Generation
    always #5 clk = ~clk;

    // 0. Feature Buffer (layer_buffer 모듈 - 16개 입력 저장용)
    layer_buffer #(
        .DATA_W(FEATURE_W),
        .DEPTH (N_MAX)
    ) u_feat_buf (
        .i_clk   (clk),
        .i_rstn  (rst_n),
        .i_wr_en (buf_wr_en),
        .i_wr_addr(buf_wr_addr),
        .i_wr_data(buf_wr_data),
        .o_data  (buf_out)
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

    // 3. Dense Layer (16 -> 8), 입력은 layer_buffer의 출력을 직결
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON),   .N_MAX(N_MAX),       .ACC_W(ACC_W), .N_MAC(N_MAC),
        .WMEM_ADDR_W(WMEM_ADDR_W), .BMEM_ADDR_W(BMEM_ADDR_W)
    ) u_dense_layer2 (
        .i_clk(clk), .i_rstn(rst_n), .i_start(start),
        .i_num_neurons(N_NEURON), .i_num_inputs(N_MAX),  // 16개 전부 유효
        .i_feature(buf_out),
        .o_wmem_addr(wmem_addr), .i_wmem_data(wmem_data),
        .o_bmem_addr(bmem_addr), .i_bmem_data(bmem_data),
        .o_result(dense_out), .o_busy(busy), .o_done(done)
    );

    // 4. Requantizer (ReLU 생략 - dense_out을 바로 requantize)
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

    // Test Scenario
    int file_fd;
    initial begin
        clk       = 0;
        rst_n     = 0;
        start     = 0;
        buf_wr_en = 0;
        buf_wr_addr = '0;
        buf_wr_data = '0;

        #20 rst_n = 1;
        #10;

        // ---- layer_buffer에 16개 테스트 값 1,2,...,16 순서로 write ----
        // (한 클럭에 하나씩만 write 가능한 구조이므로 순차적으로 넣음)
        for (int k = 0; k < N_MAX; k++) begin
            @(posedge clk);
            buf_wr_en   = 1;
            buf_wr_addr = k[$clog2(N_MAX)-1:0];
            buf_wr_data = k + 1;   // 1,2,3,...,16
        end
        @(posedge clk);
        buf_wr_en = 0;

        // write 완료 확인용 덤프
        #1;
        $display("[TB2] layer_buffer contents:");
        for (int k = 0; k < N_MAX; k++) $write("%0d ", buf_out[k]);
        $display("");

        // ---- Dense Layer2 시작 ----
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        @(posedge done);
        #10;

        // ---- 결과 확인 (콘솔에 직접 찍어서 손계산과 바로 비교) ----
        $display("[TB2] dense_out (raw, before Requant):");
        for (int g = 0; g < N_NEURON; g++) $write("%0d ", dense_out[g]);
        $display("");

        $display("[TB2] req_out (Requantize only, no ReLU):");
        for (int g = 0; g < N_NEURON; g++) $write("%0d ", req_out[g]);
        $display("");

        // Raw 파일 저장
        file_fd = $fopen("C:/Sim_out/layer2_output.bin", "wb");
        if (file_fd) begin
            for (int g = 0; g < N_NEURON; g++) begin
                $fwrite(file_fd, "%c", req_out[g]);
            end
            $fclose(file_fd);
            $display("[TB2] Layer 2 Output saved to C:/Sim_out/layer2_output.bin");
        end else begin
            $display("[TB2][ERROR] Failed to open output file - check that C:/Sim_out exists");
        end

        $finish;
    end

endmodule
