`timescale 1ns / 1ps

// =============================================================
// tb_layer3_output.sv
// layer_buffer -> dense_layer(8->1)  [Output Layer]
// ReLU/Requantize 없음 - dense_out(raw 32-bit)이 최종 출력
// =============================================================
module tb_layer3_output;

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

    logic clk;
    logic rst_n;
    logic start;
    logic done;
    logic busy;

    // ---- layer_buffer write-side control (tb가 직접 구동) ----
    logic                        buf_wr_en;
    logic [$clog2(N_MAX)-1:0]    buf_wr_addr;
    logic signed [FEATURE_W-1:0] buf_wr_data;
    logic signed [FEATURE_W-1:0] buf_out [0:N_MAX-1]; // layer_buffer o_data -> dense_layer i_feature

    // BRAM Signals
    logic [WMEM_ADDR_W-1:0] wmem_addr;
    logic [WMEM_DATA_W-1:0] wmem_data;
    logic [BMEM_ADDR_W-1:0] bmem_addr;
    logic [BMEM_DATA_W-1:0] bmem_data;

    // Layer Output (raw, no ReLU/Requant)
    logic signed [ACC_W-1:0] dense_out [0:N_NEURON-1];

    // Clock Generation
    always #5 clk = ~clk;

    // 0. Feature Buffer (layer_buffer 모듈 - 8개 입력 저장용)
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

    // 3. Dense Layer (8 -> 1), 입력은 layer_buffer의 출력을 직결
    dense_layer #(
        .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W), .BIAS_W(BIAS_W),
        .N_NEURON(N_NEURON),   .N_MAX(N_MAX),       .ACC_W(ACC_W), .N_MAC(N_MAC),
        .WMEM_ADDR_W(WMEM_ADDR_W), .BMEM_ADDR_W(BMEM_ADDR_W)
    ) u_dense_layer3 (
        .i_clk(clk), .i_rstn(rst_n), .i_start(start),
        .i_num_neurons(N_NEURON), .i_num_inputs(N_MAX),  // 8개 전부 유효
        .i_feature(buf_out),
        .o_wmem_addr(wmem_addr), .i_wmem_data(wmem_data),
        .o_bmem_addr(bmem_addr), .i_bmem_data(bmem_data),
        .o_result(dense_out), .o_busy(busy), .o_done(done)
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

        // ---- layer_buffer에 8개 테스트 값 1,2,...,8 순서로 write ----
        for (int k = 0; k < N_MAX; k++) begin
            @(posedge clk);
            buf_wr_en   = 1;
            buf_wr_addr = k[$clog2(N_MAX)-1:0];
            buf_wr_data = k + 1;   // 1,2,...,8
        end
        @(posedge clk);
        buf_wr_en = 0;

        #1;
        $display("[TB3] layer_buffer contents:");
        for (int k = 0; k < N_MAX; k++) $write("%0d ", buf_out[k]);
        $display("");

        // ---- Output Layer(dense_layer3) 시작 ----
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        @(posedge done);
        #10;

        // ---- 결과 확인 ----
        $display("[TB3] dense_out (Output Layer, raw 32-bit, 최종 출력) = %0d", dense_out[0]);

        // Raw 파일 저장 (32-bit, 4바이트, MSB first)
        file_fd = $fopen("C:/Sim_out/layer3_output.bin", "wb");
        if (file_fd) begin
            $fwrite(file_fd, "%c", dense_out[0][31:24]);
            $fwrite(file_fd, "%c", dense_out[0][23:16]);
            $fwrite(file_fd, "%c", dense_out[0][15:8]);
            $fwrite(file_fd, "%c", dense_out[0][7:0]);
            $fclose(file_fd);
            $display("[TB3] Output Layer result saved to C:/Sim_out/layer3_output.bin");
        end else begin
            $display("[TB3][ERROR] Failed to open output file - check that C:/Sim_out exists");
        end

        $finish;
    end

endmodule
