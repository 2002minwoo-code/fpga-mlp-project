`timescale 1ns / 1ps

module tb_memory_buffer;

    parameter int FEATURE_W = 8;
    parameter int N_MAX     = 16;

    logic clk;
    logic rst_n;

    // ========================================
    // Feature Buffer
    // ========================================

    localparam int F_ADDR_W =
        (N_MAX > 1) ? $clog2(N_MAX) : 1;

    logic                          feature_wr_en;
    logic [F_ADDR_W-1:0]           feature_wr_addr;
    logic signed [FEATURE_W-1:0]   feature_wr_data;

    logic signed [FEATURE_W-1:0]
        feature_out [0:N_MAX-1];


    // ========================================
    // Layer Buffer
    // ========================================

    parameter int LAYER_DEPTH = 16;

    localparam int L_ADDR_W =
        (LAYER_DEPTH > 1) ? $clog2(LAYER_DEPTH) : 1;

    logic                          layer_wr_en;
    logic [L_ADDR_W-1:0]           layer_wr_addr;
    logic signed [FEATURE_W-1:0]   layer_wr_data;

    logic signed [FEATURE_W-1:0]
        layer_out [0:LAYER_DEPTH-1];


    // ========================================
    // Clock
    // ========================================

    initial clk = 0;
    always #5 clk = ~clk;


    // ========================================
    // Feature Buffer
    // ========================================

    feature_buffer #(
        .FEATURE_W (FEATURE_W),
        .N_MAX     (N_MAX)
    ) u_feature_buffer (
        .i_clk      (clk),
        .i_rstn     (rst_n),

        .i_wr_en    (feature_wr_en),
        .i_wr_addr  (feature_wr_addr),
        .i_wr_data  (feature_wr_data),

        .o_feature  (feature_out)
    );


    // ========================================
    // Layer Buffer
    // ========================================

    layer_buffer #(
        .DATA_W (FEATURE_W),
        .DEPTH  (LAYER_DEPTH)
    ) u_layer_buffer (
        .i_clk      (clk),
        .i_rstn     (rst_n),

        .i_wr_en    (layer_wr_en),
        .i_wr_addr  (layer_wr_addr),
        .i_wr_data  (layer_wr_data),

        .o_data     (layer_out)
    );


    // ========================================
    // Test
    // ========================================

    initial begin

        rst_n = 0;

        feature_wr_en   = 0;
        feature_wr_addr = 0;
        feature_wr_data = 0;

        layer_wr_en   = 0;
        layer_wr_addr = 0;
        layer_wr_data = 0;

        #20;

        rst_n = 1;


        // ====================================
        // Feature Buffer Write
        // ====================================

        @(posedge clk);

        feature_wr_en   <= 1;
        feature_wr_addr <= 0;
        feature_wr_data <= 8'sd10;

        @(posedge clk);

        feature_wr_addr <= 1;
        feature_wr_data <= -8'sd5;

        @(posedge clk);

        feature_wr_addr <= 2;
        feature_wr_data <= 8'sd20;

        @(posedge clk);

        feature_wr_en <= 0;

        #1;


        // ====================================
        // Feature Buffer Check
        // ====================================

        $display("Feature[0] = %0d", feature_out[0]);
        $display("Feature[1] = %0d", feature_out[1]);
        $display("Feature[2] = %0d", feature_out[2]);


        // ====================================
        // Layer Buffer Write
        // ====================================

        @(posedge clk);

        layer_wr_en   <= 1;
        layer_wr_addr <= 0;
        layer_wr_data <= 8'sd30;

        @(posedge clk);

        layer_wr_addr <= 1;
        layer_wr_data <= -8'sd7;

        @(posedge clk);

        layer_wr_en <= 0;

        #1;


        // ====================================
        // Layer Buffer Check
        // ====================================

        $display("Layer[0] = %0d", layer_out[0]);
        $display("Layer[1] = %0d", layer_out[1]);


        #20;

        $finish;
    end

endmodule
