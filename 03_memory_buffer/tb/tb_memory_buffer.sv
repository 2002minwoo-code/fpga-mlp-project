// 정상작동시 결과
// Feature[0] = 10
// Feature[1] = -5
// Feature[2] = 20
// Layer[0] = 30
// Layer[1] = -7


`timescale 1ns / 1ps

module tb_memory_buffer;

    parameter int FEATURE_W = 8;
    parameter int WEIGHT_W  = 8;
    parameter int BIAS_W    = 32;

    parameter int N_FEATURES = 5;

    logic clk;
    logic rst_n;

    // --------------------------------
    // Feature Buffer signals
    // --------------------------------

    localparam int F_ADDR_W =
        (N_FEATURES <= 1) ? 1 : $clog2(N_FEATURES);

    logic                         feature_wr_en;
    logic [F_ADDR_W-1:0]          feature_wr_addr;
    logic signed [FEATURE_W-1:0]  feature_wr_data;

    logic [F_ADDR_W-1:0]          feature_rd_addr;
    logic signed [FEATURE_W-1:0]  feature_rd_data;


    // --------------------------------
    // Layer Buffer signals
    // --------------------------------

    parameter int LAYER_DEPTH = 16;

    localparam int L_ADDR_W =
        (LAYER_DEPTH <= 1) ? 1 : $clog2(LAYER_DEPTH);

    logic                         layer_wr_en;
    logic [L_ADDR_W-1:0]          layer_wr_addr;
    logic signed [FEATURE_W-1:0]  layer_wr_data;

    logic [L_ADDR_W-1:0]          layer_rd_addr;
    logic signed [FEATURE_W-1:0]  layer_rd_data;


    // --------------------------------
    // Clock
    // --------------------------------

    initial clk = 0;

    always #5 clk = ~clk;


    // --------------------------------
    // Feature Buffer
    // --------------------------------

    feature_buffer #(
        .FEATURE_W  (FEATURE_W),
        .N_FEATURES (N_FEATURES)
    ) u_feature_buffer (
        .clk     (clk),
        .rst_n   (rst_n),

        .wr_en   (feature_wr_en),
        .wr_addr (feature_wr_addr),
        .wr_data (feature_wr_data),

        .rd_addr (feature_rd_addr),
        .rd_data (feature_rd_data)
    );


    // --------------------------------
    // Layer Buffer
    // --------------------------------

    layer_buffer #(
        .DATA_W (FEATURE_W),
        .DEPTH  (LAYER_DEPTH)
    ) u_layer_buffer (
        .clk     (clk),
        .rst_n   (rst_n),

        .wr_en   (layer_wr_en),
        .wr_addr (layer_wr_addr),
        .wr_data (layer_wr_data),

        .rd_addr (layer_rd_addr),
        .rd_data (layer_rd_data)
    );


    // --------------------------------
    // Test
    // --------------------------------

    initial begin

        rst_n = 0;

        feature_wr_en   = 0;
        feature_wr_addr = 0;
        feature_wr_data = 0;
        feature_rd_addr = 0;

        layer_wr_en   = 0;
        layer_wr_addr = 0;
        layer_wr_data = 0;
        layer_rd_addr = 0;

        #20;

        rst_n = 1;


        // ==========================
        // Feature Buffer Write
        // ==========================

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


        // ==========================
        // Feature Buffer Read
        // ==========================

        feature_rd_addr = 0;
        #1;
        $display("Feature[0] = %0d", feature_rd_data);

        feature_rd_addr = 1;
        #1;
        $display("Feature[1] = %0d", feature_rd_data);

        feature_rd_addr = 2;
        #1;
        $display("Feature[2] = %0d", feature_rd_data);


        // ==========================
        // Layer Buffer Write
        // ==========================

        @(posedge clk);

        layer_wr_en   <= 1;
        layer_wr_addr <= 0;
        layer_wr_data <= 8'sd30;

        @(posedge clk);

        layer_wr_addr <= 1;
        layer_wr_data <= -8'sd7;

        @(posedge clk);

        layer_wr_en <= 0;


        // ==========================
        // Layer Buffer Read
        // ==========================

        layer_rd_addr = 0;
        #1;
        $display("Layer[0] = %0d", layer_rd_data);

        layer_rd_addr = 1;
        #1;
        $display("Layer[1] = %0d", layer_rd_data);


        #20;

        $finish;
    end

endmodule
