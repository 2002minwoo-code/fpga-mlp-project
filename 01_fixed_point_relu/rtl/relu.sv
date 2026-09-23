// =============================================================
// relu_layer.sv (N_NEURON 배열 지원 독립 ReLU 모듈)
// =============================================================
`timescale 1ns / 1ps

module relu_layer #(
    parameter int IN_W     = 32, // 입력 비트폭 (ACC_W)
    parameter int N_NEURON = 16  // 처리할 뉴런 개수
)(
    input  logic signed [IN_W-1:0] in_data  [0:N_NEURON-1],
    output logic signed [IN_W-1:0] out_data [0:N_NEURON-1]
);

    genvar i;
    generate
        for (i = 0; i < N_NEURON; i++) begin : gen_relu
            always_comb begin
                if (in_data[i] < 0)
                    out_data[i] = '0;
                else
                    out_data[i] = in_data[i];
            end
        end
    endgenerate

endmodule
