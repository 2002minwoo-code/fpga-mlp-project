// =============================================================
//  mac_unit.sv  —  Serial MAC Unit (뉴런 1개 연산 엔진)
//
//  Dense layer로부터 데이터를 통째로(행렬/리스트) 받고,
//  neuron_idx로 지금 계산할 뉴런의 줄을 골라 계산한다.
//      result = bias[neuron_idx]
//             + Σ_i ( weight[neuron_idx][i] × feature[i] )
//
//  - weight : 2차원 행렬 [뉴런][feature]  (뉴런 전체치)
//  - feature: 1차원 리스트 [feature]       (지금 층 입력)
//  - bias   : 1차원 리스트 [뉴런]           (뉴런 전체치)
//  내부에서 feature 번호(idx)만 0→N-1 로 훑고,
//  뉴런 번호(neuron_idx)는 계산 내내 고정.
//
//  제어: start / busy / done.  모든 데이터 signed.
// =============================================================
module mac_unit #(
    parameter int FEATURE_W = 8,    // feature 비트폭
    parameter int WEIGHT_W  = 8,    // weight 비트폭
    parameter int BIAS_W    = 32,   // bias 비트폭
    parameter int ACC_W     = 32,   // 누적기 비트폭
    parameter int N_MAX     = 16,   // 뉴런 1개 최대 입력(feature) 수
    parameter int N_NEURON  = 16    // 이 층의 뉴런 개수 (행렬의 줄 수)
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        start,        // 1펄스: 뉴런 연산 시작
    input  logic [$clog2(N_MAX+1)-1:0]  n_feat,       // 이번 층의 feature 개수
    input  logic [$clog2(N_NEURON)-1:0] neuron_idx,   // 지금 계산할 뉴런 번호 (줄 선택)

    // 통째로 받는 데이터
    input  logic signed [FEATURE_W-1:0] i_mac_feature [0:N_MAX-1],            // [feature]
    input  logic signed [WEIGHT_W-1:0]  i_mac_weight  [0:N_NEURON-1][0:N_MAX-1], // [뉴런][feature]
    input  logic signed [BIAS_W-1:0]    i_mac_bias    [0:N_NEURON-1],         // [뉴런]

    output logic                        busy,
    output logic                        done,         // 완료 시 1클럭 펄스
    output logic signed [ACC_W-1:0]     result        // 뉴런 출력
);

    localparam int IDX_W  = $clog2(N_MAX);
    localparam int PROD_W = FEATURE_W + WEIGHT_W;

    typedef enum logic [1:0] {IDLE, RUN, FIN} state_t;
    state_t state;

    logic [IDX_W-1:0]        idx;   // 지금 몇 번째 feature 처리 중인지 (뒤 인덱스)
    logic signed [ACC_W-1:0] acc;

    // 지금 뉴런(neuron_idx)의 idx번째 항을 골라서 곱셈
    //   weight[neuron_idx][idx] × feature[idx]
    logic signed [PROD_W-1:0] product;
    assign product = i_mac_weight[neuron_idx][idx] * i_mac_feature[idx];

    // 곱을 누적기 폭으로 부호 확장
    logic signed [ACC_W-1:0] product_ext;
    assign product_ext = {{(ACC_W-PROD_W){product[PROD_W-1]}}, product};

    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= IDLE;
            idx    <= '0;
            acc    <= '0;
            done   <= 1'b0;
            result <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                // 시작: 누적기를 이 뉴런의 bias로 초기화
                IDLE: begin
                    if (start) begin
                        acc   <= i_mac_bias[neuron_idx];
                        idx   <= '0;
                        state <= RUN;
                    end
                end

                // 실행: feature 번호만 0→n_feat-1 로 증가시키며 누적
                RUN: begin
                    acc <= acc + product_ext;
                    if (idx == n_feat - 1)
                        state <= FIN;
                    else
                        idx <= idx + 1'b1;
                end

                // 완료: 결과 확정 + done 펄스
                FIN: begin
                    result <= acc;
                    done   <= 1'b1;
                    state  <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
