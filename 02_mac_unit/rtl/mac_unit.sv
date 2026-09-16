// =============================================================
//  mac_unit.sv  —  Serial MAC Unit (뉴런 1개 연산 엔진)
//
//  start 한 번 주면 n_feat 개의 feature × weight 를 순서대로
//  곱해서 누적한다. 누적기는 bias 로 시작 →
//      result = bias + Σ (feature[i] × weight[i])
//
//  제어: start / busy / done.  모든 데이터 signed.
//
//  ※ parameter는 팀 공통값(연습용 임시)을 기본으로 넣어둠.
//    팀에서 확정되면 아래 숫자만 맞추면 됨. (혹은 상위 모듈에서
//    parameter로 덮어쓰면 됨 — 값이 모듈 안에 박혀있지 않음)
// =============================================================
module mac_unit #(
    parameter int FEATURE_W = 8,    // feature 비트폭
    parameter int WEIGHT_W  = 8,    // weight 비트폭
    parameter int BIAS_W    = 32,   // bias 비트폭
    parameter int ACC_W     = 32,   // 누적기 비트폭
    parameter int N_MAX     = 16    // 뉴런 1개 최대 입력 수
)(
    input  logic                        clk,
    input  logic                        rst_n,     // active-low 리셋
    input  logic                        start,     // 1펄스: 새 뉴런 연산 시작
    input  logic [$clog2(N_MAX+1)-1:0]  n_feat,    // 이번 뉴런의 feature 개수
    input  logic signed [BIAS_W-1:0]    bias,      // 누적기 초기값 (bias)
    input  logic signed [FEATURE_W-1:0] feature,   // addr가 가리키는 feature
    input  logic signed [WEIGHT_W-1:0]  weight,    // addr가 가리키는 weight
    output logic [$clog2(N_MAX)-1:0]    addr,      // 읽을 feature/weight 인덱스
    output logic                        busy,      // 연산 중이면 1
    output logic                        done,      // 완료 시 1클럭 펄스
    output logic signed [ACC_W-1:0]     result     // 최종 누적 결과
);

    localparam int IDX_W  = $clog2(N_MAX);
    localparam int PROD_W = FEATURE_W + WEIGHT_W;   // 곱셈 결과 폭 = 16

    // ---- FSM 상태 ----
    typedef enum logic [1:0] {IDLE, RUN, FIN} state_t;
    state_t state;

    logic [IDX_W-1:0]        idx;   // 지금 몇 번째 feature 처리 중인지
    logic signed [ACC_W-1:0] acc;   // 누적기

    // ---- 곱셈 (signed × signed) ----
    logic signed [PROD_W-1:0] product;
    assign product = feature * weight;

    // ---- 곱을 누적기 폭으로 부호 확장 ----
    logic signed [ACC_W-1:0] product_ext;
    assign product_ext = {{(ACC_W-PROD_W){product[PROD_W-1]}}, product};

    // 현재 인덱스를 addr로 → 외부(memory_buffer)가 feature[idx]/weight[idx] 공급
    assign addr = idx;
    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= IDLE;
            idx    <= '0;
            acc    <= '0;
            done   <= 1'b0;
            result <= '0;
        end else begin
            done <= 1'b0;   // done은 기본 0, FIN에서만 1클럭 올림

            case (state)
                // --- 대기: start 오면 누적기를 bias로 초기화하고 시작 ---
                //     (bias는 signed → acc에 자동 부호확장되어 실림)
                IDLE: begin
                    if (start) begin
                        acc   <= bias;
                        idx   <= '0;
                        state <= RUN;
                    end
                end

                // --- 실행: 매 클럭 한 항씩 누적, 인덱스 증가 ---
                RUN: begin
                    acc <= acc + product_ext;
                    if (idx == n_feat - 1)
                        state <= FIN;        // 마지막 항까지 넣었으면 종료로
                    else
                        idx <= idx + 1'b1;
                end

                // --- 완료: 결과 확정하고 done 펄스 ---
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
