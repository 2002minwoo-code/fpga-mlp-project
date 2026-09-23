// =============================================================
// dense_layer.sv (v5 - MAC 8개 병렬, act 인터페이스 제거)
//   
//   N=16 → 2 groups, N=8 → 1 group
//   raw acc 출력
// =============================================================
module dense_layer #(
    parameter int FEATURE_W = 8,
    parameter int WEIGHT_W  = 8,
    parameter int BIAS_W    = 32,
    parameter int N_NEURON  = 16,
    parameter int N_MAX     = 16,
    parameter int ACC_W     = 32,
    parameter int N_MAC     = 8            // 병렬 MAC 개수
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                          i_dl_start,
    input  logic [$clog2(N_NEURON+1)-1:0] i_num_neurons,  // 16 or 8
    input  logic [$clog2(N_MAX+1)-1:0]    i_num_inputs,   // M

    input  logic signed [FEATURE_W-1:0] i_dl_feature [0:N_MAX-1],
    input  logic signed [WEIGHT_W-1:0]  i_dl_weight  [0:N_NEURON-1][0:N_MAX-1],
    input  logic signed [BIAS_W-1:0]    i_dl_bias    [0:N_NEURON-1],

    // raw MAC 결과 (requantize/ReLU 전) - controller가 받아서 처리
    output logic signed [ACC_W-1:0]       o_dl_result [0:N_NEURON-1],
    output logic                          o_dl_busy,
    output logic                          o_dl_done
);

    localparam int N_GROUP_MAX = N_NEURON / N_MAC;   // 16/8 = 2
    localparam int GIDX_W = (N_GROUP_MAX > 1) ? $clog2(N_GROUP_MAX) : 1;

    typedef enum logic [1:0] {S_IDLE, S_MAC_START, S_MAC_WAIT, S_DONE} state_t;
    state_t state, state_n;

    logic [GIDX_W-1:0] group_idx;

    // ---- MAC 8개와의 연결 ----
    logic                    mac_start;
    logic                    mac_done  [0:N_MAC-1];
    logic signed [ACC_W-1:0] mac_result[0:N_MAC-1];

    // 이번 group의 시작 뉴런 번호
    logic [$clog2(N_NEURON+1)-1:0] base;
    assign base = group_idx * N_MAC;

    // 마지막 group인가?
    logic last_group;
    assign last_group = (base + N_MAC >= i_num_neurons);

    // ---- FSM ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_n;
    end

    always_comb begin
        state_n = state;
        case (state)
            S_IDLE:      if (i_dl_start) state_n = S_MAC_START;
            S_MAC_START: state_n = S_MAC_WAIT;
            S_MAC_WAIT:  if (mac_done[0])            // 8개 모두 동일 타이밍
                             state_n = last_group ? S_DONE : S_MAC_START;
            S_DONE:      state_n = S_IDLE;
            default:     state_n = S_IDLE;
        endcase
    end

    assign mac_start = (state == S_MAC_START);

    // ---- datapath ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group_idx <= '0;
            o_dl_busy <= 1'b0;
            o_dl_done <= 1'b0;
        end else begin
            o_dl_done <= 1'b0;
            case (state)
                S_IDLE: if (i_dl_start) begin
                    group_idx <= '0;
                    o_dl_busy <= 1'b1;
                end
                S_MAC_WAIT: if (mac_done[0]) begin
                    // 결과 저장 (유효한 뉴런만)
                    for (int g = 0; g < N_MAC; g++) begin
                        if (base + g < i_num_neurons)
                            o_dl_result[base + g] <= mac_result[g];
                    end
                    if (last_group) o_dl_done <= 1'b1;
                    else            group_idx <= group_idx + 1'b1;
                end
                S_DONE: o_dl_busy <= 1'b0;
                default: ;
            endcase
        end
    end

    // ---- MAC 8개 instantiate ----
    genvar g;
    generate
        for (g = 0; g < N_MAC; g++) begin : gen_mac
            logic [$clog2(N_NEURON)-1:0] nidx;
            assign nidx = base[$clog2(N_NEURON)-1:0] + g[$clog2(N_NEURON)-1:0];

            mac_unit #(
                .FEATURE_W(FEATURE_W), .WEIGHT_W(WEIGHT_W),
                .BIAS_W(BIAS_W), .ACC_W(ACC_W),
                .N_MAX(N_MAX), .N_NEURON(N_NEURON)
            ) u_mac (
                .clk          (clk),
                .rst_n        (rst_n),
                .start        (mac_start),
                .n_feat       (i_num_inputs),
                .neuron_idx   (nidx),
                .i_mac_feature(i_dl_feature),
                .i_mac_weight (i_dl_weight[nidx]), // 수정됨: 해당 뉴런의 1D 배열만 잘라서 전달
                .i_mac_bias   (i_dl_bias[nidx]),   // 수정됨: 해당 뉴런의 단일 값만 잘라서 전달
                .busy         (),              // 미사용
                .done         (mac_done[g]),
                .result       (mac_result[g])
            );
        end
    endgenerate

endmodule
