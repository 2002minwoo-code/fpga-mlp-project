# 공통 Parameter

아직 MLP 구조와 Fixed-Point 형식이 확정되지 않았으므로 아래 값은 연습용 임시값입니다.

알고리즘팀의 결과가 나오면 모든 팀원이 같은 값으로 수정합니다.

```systemverilog
// MLP 구조
parameter int N_FEATURES = 5;
parameter int N_HIDDEN1  = 16;
parameter int N_HIDDEN2  = 8;
parameter int N_OUTPUTS  = 1;

// 데이터 비트폭
parameter int FEATURE_W = 8;
parameter int WEIGHT_W  = 8;
parameter int BIAS_W    = 32;
parameter int HIDDEN_W  = 8;
parameter int ACC_W     = 32;
parameter int OUTPUT_W  = 16;

// 소수부 비트 수
parameter int FEATURE_FRAC = 4;
parameter int WEIGHT_FRAC  = 4;
parameter int BIAS_FRAC    = 8;
parameter int HIDDEN_FRAC  = 4;
parameter int OUTPUT_FRAC  = 8;

// UART
parameter int CLK_FREQ_HZ = 100_000_000;
parameter int BAUD_RATE   = 115_200;
```

## 이름 설명

- `N_FEATURES`: 입력 Feature 개수
- `N_HIDDEN1`: 첫 번째 Hidden Layer 뉴런 개수
- `N_HIDDEN2`: 두 번째 Hidden Layer 뉴런 개수
- `N_OUTPUTS`: 최종 출력 개수
- `FEATURE_W`: Feature 비트폭
- `WEIGHT_W`: Weight 비트폭
- `BIAS_W`: Bias 비트폭
- `HIDDEN_W`: Hidden Layer 출력 비트폭
- `ACC_W`: MAC 누산 결과 비트폭
- `OUTPUT_W`: 최종 출력 비트폭
- `*_FRAC`: 각 데이터의 소수부 비트 수
- `CLK_FREQ_HZ`: FPGA에 입력되는 Clock 주파수
- `BAUD_RATE`: UART 통신속도

모든 연산 데이터는 기본적으로 `signed`를 사용합니다.

각 모듈에서는 필요한 Parameter만 가져와서 사용합니다.
