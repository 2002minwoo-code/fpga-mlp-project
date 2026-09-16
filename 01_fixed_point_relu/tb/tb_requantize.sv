`timescale 1ns/1ps

module tb_requantize;
    logic signed [31:0] in_data;
    logic signed [7:0]  out_data;

    // DUT (Design Under Test) 연결
    requantize #(
        .IN_W(32), .IN_FRAC(8),
        .OUT_W(8), .OUT_FRAC(4)
    ) u_dut (
        .in_data (in_data),
        .out_data(out_data)
    );

    initial begin
        // 케이스 1: 정상값 +2.0 (Q24.8 기준 32'h0200) -> 출력 +2.0 (Q4.4 기준 8'h20) 예상
        in_data = 32'h0000_0200; #20;

        // 케이스 2: 상한 포화 테스트 (너무 큰 양수) -> 출력 8'h7F (+7.9375) 예상
        in_data = 32'h0000_E000; #20;

        // 케이스 3: 하한 포화 테스트 (너무 큰 음수) -> 출력 8'h80 (-8.0) 예상
        in_data = 32'hFFFF_2000; #20;

        $stop;
    end
endmodule
