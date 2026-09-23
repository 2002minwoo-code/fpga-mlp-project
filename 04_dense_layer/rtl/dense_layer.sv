// =============================================================
// dense_layer.sv (2.BRAM 추가 및 Read Latency 타이밍 교정 완료)
// =============================================================
module dense_layer #(
    parameter int FEATURE_W = 8,
    parameter int WEIGHT_W  = 8,
    parameter int BIAS_W    = 32,
    parameter int N_NEURON  = 16,
    parameter int N_MAX     = 16,
    parameter int ACC_W     = 32,
    parameter int N_MAC     = 8,

    parameter int WMEM_DATA_W = N_MAC * WEIGHT_W,                  // 64 bits
    parameter int BMEM_DATA_W = N_MAC * BIAS_W,                    // 256 bits
    parameter int WMEM_ADDR_W = $clog2((N_NEURON/N_MAC) * N_MAX),  // 5 bits
    parameter int BMEM_ADDR_W = (N_NEURON/N_MAC > 1) ? $clog2(N_NEURON/N_MAC) : 1
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                         i_dl_start,
    input  logic [$clog2(N_NEURON+1)-1:0] i_num_neurons,
    input  logic [$clog2(N_MAX+1)-1:0]    i_num_inputs,

    input  logic signed [FEATURE_W-1:0] i_dl_feature [0:N_MAX-1],

    // BRAM 읽기 인터페이스
    output logic [WMEM_ADDR_W-1:0] o_wmem_addr,
    input  logic [WMEM_DATA_W-1:0] i_wmem_rdata,

    output logic [BMEM_ADDR_W-1:0] o_bmem_addr,
    input  logic [BMEM_DATA_W-1:0] i_bmem_rdata,

    output logic signed [ACC_W-1:0] o_dl_result [0:N_NEURON-1],
    output logic                    o_dl_busy,
    output logic                    o_dl_done
);

    localparam int N_GROUP_MAX = N_NEURON / N_MAC;
    localparam int GIDX_W = (N_GROUP_MAX > 1) ? $clog2(N_GROUP_MAX) : 1;

    // FSM 상태 정의
    typedef enum logic [2:0] {
        S_IDLE      = 3'b000,
        S_REQ_BIAS  = 3'b001, // Bias 및 첫 번째 Weight(0번) 주소 동시에 요청
        S_WAIT_DATA = 3'b010, // BRAM 1-Clock Read Latency 대기 & 두 번째 Weight(1번) 주소 요청
        S_MAC_RUN   = 3'b011, // MAC 연산 수행 & 연속 Weight 주소 요청
        S_STORE     = 3'b100, // 결과 저장
        S_DONE      = 3'b101  // 연산 완료
    } state_t;

    state_t state, state_n;

    logic [GIDX_W-1:0]          group_idx;
    logic [$clog2(N_MAX+1)-1:0]  feat_idx;

    // MAC 연결 제어 신호
    logic mac_clr;
    logic mac_en;
    logic signed [ACC_W-1:0] mac_out [0:N_MAC-1];

    logic [$clog2(N_NEURON+1)-1:0] base;
    assign base = group_idx * N_MAC;

    logic last_group;
    assign last_group = (base + N_MAC >= i_num_neurons);

    // FSM State Register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_n;
    end

    // FSM Next State Logic
    always_comb begin
        state_n = state;
        case (state)
            S_IDLE:      if (i_dl_start) state_n = S_REQ_BIAS;
            S_REQ_BIAS:  state_n = S_WAIT_DATA;
            S_WAIT_DATA: state_n = S_MAC_RUN;
            S_MAC_RUN:   if (feat_idx == i_num_inputs - 1) state_n = S_STORE;
            S_STORE:     state_n = last_group ? S_DONE : S_REQ_BIAS;
            S_DONE:      state_n = S_IDLE;
            default:     state_n = S_IDLE;
        endcase
    end

    // MAC 제어 신호 (feat_idx == 0일 때 Bias + Feat[0]*Weight[0] 수행)
    assign mac_clr = (state == S_MAC_RUN) && (feat_idx == 0);
    assign mac_en  = (state == S_MAC_RUN) && (feat_idx > 0) && (feat_idx < i_num_inputs);

    // BRAM 주소 생성 및 데이터패스 제어
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group_idx   <= '0;
            feat_idx    <= '0;
            o_wmem_addr <= '0;
            o_bmem_addr <= '0;
            o_dl_busy   <= 1'b0;
            o_dl_done   <= 1'b0;
        end else begin
            o_dl_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (i_dl_start) begin
                        group_idx <= '0;
                        o_dl_busy <= 1'b1;
                    end
                end

                // [1단계] Bias 및 첫 번째 Weight(0번) 주소 동시에 요청
                S_REQ_BIAS: begin
                    o_bmem_addr <= group_idx[BMEM_ADDR_W-1:0];
                    o_wmem_addr <= (group_idx * i_num_inputs) + '0;
                    feat_idx    <= '0;
                end

                // [2단계] BRAM Latency 대기 & 두 번째 Weight(1번) 주소 미리 요청 (Prefetch)
                S_WAIT_DATA: begin
                    if (i_num_inputs > 1)
                        o_wmem_addr <= (group_idx * i_num_inputs) + 1'b1;
                end

                // [3단계] MAC 연산 진행 & 다음 Weight 주소 연속 요청
                S_MAC_RUN: begin
                    if (feat_idx < i_num_inputs - 1) begin
                        feat_idx    <= feat_idx + 1'b1;
                        o_wmem_addr <= (group_idx * i_num_inputs) + (feat_idx + 2'd2);
                    end else begin
                        feat_idx    <= feat_idx + 1'b1;
                    end
                end

                // [4단계] 8개 MAC 연산 결과 레지스터 저장
                S_STORE: begin
                    for (int g = 0; g < N_MAC; g++) begin
                        if (base + g < i_num_neurons)
                            o_dl_result[base + g] <= mac_out[g];
                    end

                    if (last_group) begin
                        o_dl_done <= 1'b1;
                    end else begin
                        group_idx <= group_idx + 1'b1;
                    end
                end

                S_DONE: begin
                    o_dl_busy <= 1'b0;
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------
    // MAC 하위 모듈 8개 인스턴스화
    // -------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < N_MAC; g++) begin : gen_mac
            logic signed [WEIGHT_W-1:0] w_val;
            logic signed [BIAS_W-1:0]   b_val;

            assign w_val = $signed(i_wmem_rdata[g*WEIGHT_W +: WEIGHT_W]);
            assign b_val = $signed(i_bmem_rdata[g*BIAS_W +: BIAS_W]);

            mac_unit #(
                .FEATURE_W(FEATURE_W),
                .WEIGHT_W(WEIGHT_W),
                .BIAS_W(BIAS_W),
                .ACC_W(ACC_W)
            ) u_mac (
                .clk    (clk),
                .rst_n  (rst_n),
                .clr    (mac_clr),
                .en     (mac_en),
                .b_in   (b_val),
                .f_in   (i_dl_feature[feat_idx]),
                .w_in   (w_val),
                .acc_out(mac_out[g])
            );
        end
    endgenerate

endmodule
