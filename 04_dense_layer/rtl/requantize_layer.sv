// =============================================================
// requantize_layer.sv (Round-half-up & Saturation 재양자화 모듈)
// =============================================================
`timescale 1ns / 1ps

module requantize_layer #(
    parameter int IN_W     = 32, // 입력 비트폭 (ACC_W)
    parameter int IN_FRAC  = 8,  // 입력 소수부 비트폭
    parameter int OUT_W    = 8,  // 출력 비트폭 (FEATURE_W)
    parameter int OUT_FRAC = 4,  // 출력 소수부 비트폭
    parameter int N_NEURON = 16  // 처리할 뉴런 개수
)(
    input  logic signed [IN_W-1:0]  in_data  [0:N_NEURON-1], // ReLU 거친 32-bit 데이터
    output logic signed [OUT_W-1:0] out_data [0:N_NEURON-1]  // 다음 레이어 입력용 8-bit 데이터
);

    // 1. 시프트할 비트 수 계산 (소수점 위치 맞춤)
    localparam int SHIFT_AMT = IN_FRAC - OUT_FRAC;

    // 2. 출력 비트폭 범위 표현 한계값 (Signed 기준)
    localparam logic signed [IN_W-1:0] MAX_VAL = $signed((1 << (OUT_W - 1)) - 1);
    localparam logic signed [IN_W-1:0] MIN_VAL = $signed(-(1 << (OUT_W - 1)));

    genvar i;
    generate
        for (i = 0; i < N_NEURON; i++) begin : gen_requant
            logic signed [IN_W-1:0] rounded_data;
            logic signed [IN_W-1:0] shifted_data;

            always_comb begin
                // [Step 1] Rounding & Shift (반올림 및 비트 축소)
                if (SHIFT_AMT > 0) begin
                    // 버려지는 MSB자리에 1을 더해 Round-half-up 처리
                    rounded_data = in_data[i] + (1 << (SHIFT_AMT - 1));
                    shifted_data = rounded_data >>> SHIFT_AMT; // 산술 시프트
                end else begin
                    shifted_data = in_data[i];
                end

                // [Step 2] Saturation (포화 처리)
                if (shifted_data > MAX_VAL) begin
                    out_data[i] = MAX_VAL[OUT_W-1:0]; // 상한값 고정 (+127)
                end else if (shifted_data < MIN_VAL) begin
                    out_data[i] = MIN_VAL[OUT_W-1:0]; // 하한값 고정 (-128)
                end else begin
                    out_data[i] = shifted_data[OUT_W-1:0]; // 정상 범위 잘라내기
                end
            end
        end
    endgenerate

endmodule
