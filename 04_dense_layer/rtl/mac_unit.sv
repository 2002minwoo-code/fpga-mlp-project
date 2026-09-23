// =============================================================
//  mac_unit.sv   -  Serial MAC Unit (수정됨: 슬라이싱된 데이터 수신)
// =============================================================
module mac_unit #(
    parameter int FEATURE_W = 8,
    parameter int WEIGHT_W  = 8,
    parameter int BIAS_W    = 32,
    parameter int ACC_W     = 32,
    parameter int N_MAX     = 16,
    parameter int N_NEURON  = 16
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        start,
    input  logic [$clog2(N_MAX+1)-1:0]  n_feat,
    input  logic [$clog2(N_NEURON)-1:0] neuron_idx,  // 포트 유지를 위해 남겨둠 (내부 인덱싱에는 미사용)

    // 통째로 받던 배열을 슬라이싱된 1차원 배열 및 단일 값으로 수정
    input  logic signed [FEATURE_W-1:0] i_mac_feature [0:N_MAX-1],  
    input  logic signed [WEIGHT_W-1:0]  i_mac_weight  [0:N_MAX-1], // [뉴런] 차원 제거됨
    input  logic signed [BIAS_W-1:0]    i_mac_bias,                // 1차원 배열에서 단일 값으로 변경

    output logic                        busy,
    output logic                        done,
    output logic signed [ACC_W-1:0]     result
);

    localparam int IDX_W  = $clog2(N_MAX);
    localparam int PROD_W = FEATURE_W + WEIGHT_W;

    typedef enum logic [1:0] {IDLE, RUN, FIN} state_t;
    state_t state;

    logic [IDX_W-1:0]        idx;
    logic signed [ACC_W-1:0] acc;

    // 수정됨: 이미 내 뉴런의 가중치만 들어오므로 neuron_idx로 2차원 접근을 할 필요가 없음
    logic signed [PROD_W-1:0] product;
    assign product = i_mac_weight[idx] * i_mac_feature[idx];

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
                IDLE: begin
                    if (start) begin
                        acc   <= i_mac_bias; // 수정됨: 단일 값으로 바로 초기화
                        idx   <= '0;
                        state <= RUN;
                    end
                end

                RUN: begin
                    acc <= acc + product_ext;
                    if (idx == n_feat - 1)
                        state <= FIN;
                    else
                        idx <= idx + 1'b1;
                end

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
