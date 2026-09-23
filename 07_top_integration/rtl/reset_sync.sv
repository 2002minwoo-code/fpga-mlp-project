`timescale 1ns/1ps
`default_nettype none

// Active-low reset synchronizer
// - 리셋 인가: 클록을 기다리지 않고 즉시 처리
// - 리셋 해제: 두 번의 클록 상승 에지를 거쳐 처리
module reset_sync (
    input  wire clk,
    input  wire async_rst_n,
    output wire rst_n
);

    // 동기화용 플립플롭임을 합성/배치 도구에 알린다.
    (* ASYNC_REG = "TRUE" *)
    reg [1:0] sync_ff;

    always @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) begin
            sync_ff <= 2'b00;
        end else begin
            sync_ff[0] <= 1'b1;
            sync_ff[1] <= sync_ff[0];
        end
    end

    assign rst_n = sync_ff[1];

endmodule

`default_nettype wire
