`timescale 1ns/1ps
`default_nettype none

// Asynchronous assertion, two-clock synchronous release. rst_n is active low.
module reset_sync (
    input  wire clk,
    input  wire async_rst_n,
    output wire rst_n
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_ff;
    always @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) sync_ff <= 2'b00;
        else              sync_ff <= {sync_ff[0], 1'b1};
    end
    assign rst_n = sync_ff[1];
endmodule
`default_nettype wire
