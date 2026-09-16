module requantize #(
    parameter int IN_W     = 32, // 입력 비트폭 (ACC_W)
    parameter int IN_FRAC  = 8,  // 입력 소수부 비트폭 (ACC_FRAC)
    parameter int OUT_W    = 8,  // 출력 비트폭 (HIDDEN_W 또는 OUTPUT_W)
    parameter int OUT_FRAC = 4   // 출력 소수부 비트폭 (HIDDEN_FRAC 또는 OUTPUT_FRAC)
)(
    input  logic signed [IN_W-1:0]  in_data,  // MAC 누적 결과값
    output logic signed [OUT_W-1:0] out_data  // 재양자화 완료된 값
);

    // 1. 오른쪽으로 시프트할 비트 수 계산 
    localparam int SHIFT_AMT = IN_FRAC - OUT_FRAC;

    // 2. 출력 타입의 표현 한계값 (Signed 기준)
    // OUT_W가 8일 때: MAX = +127, MIN = -128
    // OUT_W가 16일 때: MAX = +32767, MIN = -32768
    localparam logic signed [IN_W-1:0] MAX_VAL = $signed((1 << (OUT_W - 1)) - 1);
    localparam logic signed [IN_W-1:0] MIN_VAL = $signed(-(1 << (OUT_W - 1)));

    // 내부 연산용 변수
    logic signed [IN_W-1:0] rounded_data;
    logic signed [IN_W-1:0] shifted_data;

    always_comb begin
        // [Step 1] Rounding & Shift (반올림 및 비트 축소)
        if (SHIFT_AMT > 0) begin
            // 버려지는 비트의 최상위 비트자리에 1을 더해 반올림(Round-half-up) 처리
            rounded_data = in_data + (1 << (SHIFT_AMT - 1));
            shifted_data = rounded_data >>> SHIFT_AMT; // 산술 시프트 (부호 유지)
        end else begin
            shifted_data = in_data;
        end

        // [Step 2] Saturation (포화 처리)
        if (shifted_data > MAX_VAL) begin
            out_data = MAX_VAL[OUT_W-1:0]; // 최대 상한값으로 고정 (Clamping)
        end else if (shifted_data < MIN_VAL) begin
            out_data = MIN_VAL[OUT_W-1:0]; // 최저 하한값으로 고정 (Clamping)
        end else begin
            out_data = shifted_data[OUT_W-1:0]; // 정상 범위 내 데이터 잘라내기
        end
    end

endmodule
