`timescale 1ns/1ps

module tb_relu;
    parameter int WIDTH = 8;

    logic signed [WIDTH-1:0] in_data;
    logic signed [WIDTH-1:0] out_data;

    // DUT (Design Under Test) ?????
    relu #(
        .WIDTH(WIDTH)
    ) u_dut (
        .in_data (in_data),
        .out_data(out_data)
    );

    initial begin
        // ??? 1: ?? (+2.0 -> 8'h20) => ?? 8'h20 (+2.0) ??
        in_data = 8'h20; #20;

        // ??? 2: ?? (-2.0 -> 8'hE0) => ?? 8'h00 (0.0) ??
        in_data = 8'hE0; #20;

        // ??? 3: 0 (0.0 -> 8'h00) => ?? 8'h00 (0.0) ??
        in_data = 8'h00; #20;

        // ??? 4: ?? ?? (+7.9375 -> 8'h7F) => ?? 8'h7F ??
        in_data = 8'h7F; #20;

        // ??? 5: ?? ?? (-8.0 -> 8'h80) => ?? 8'h00 (0.0) ??
        in_data = 8'h80; #20;

        $stop;
    end
endmodule
