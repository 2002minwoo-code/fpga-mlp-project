module relu #(
    parameter int WIDTH = 8
)(
    input  logic signed [WIDTH-1:0] in_data,
    output logic signed [WIDTH-1:0] out_data
);

    always_comb begin
              if (in_data < 0) begin
            out_data = {WIDTH{1'b0}}; // 음수면 0으로 채움
        end else begin
            out_data = in_data;       // 양수면 그대로 출력
        end
    end

endmodule
