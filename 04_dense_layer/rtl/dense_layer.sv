`timescale 1ns / 1ps

module dense_layer #(
    parameter int FEATURE_W = 8,
    parameter int WEIGHT_W  = 8,
    parameter int BIAS_W    = 32,
    parameter int N_NEURON  = 16,
    parameter int N_MAX     = 16,
    parameter int ACC_W     = 32,
    parameter int N_MAC     = 8,

    parameter int WMEM_DATA_W = N_MAC * WEIGHT_W,
    parameter int BMEM_DATA_W = N_MAC * BIAS_W,
    parameter int WMEM_ADDR_W = (((N_NEURON + N_MAC - 1) / N_MAC) * N_MAX > 1) ? 
                                $clog2(((N_NEURON + N_MAC - 1) / N_MAC) * N_MAX) : 1,
    parameter int BMEM_ADDR_W = (((N_NEURON + N_MAC - 1) / N_MAC) > 1) ? 
                                $clog2((N_NEURON + N_MAC - 1) / N_MAC) : 1
)(
    input  logic i_clk,
    input  logic i_rstn,

    // Control & Config
    input  logic                         i_start,
    input  logic [$clog2(N_NEURON+1)-1:0] i_num_neurons,
    input  logic [$clog2(N_MAX+1)-1:0]    i_num_inputs,

    // Feature Input
    input  logic signed [FEATURE_W-1:0] i_feature [0:N_MAX-1],

    // BRAM Interfaces (both are SYNCHRONOUS / 1-cycle read latency BRAMs)
    output logic [WMEM_ADDR_W-1:0] o_wmem_addr,
    input  logic [WMEM_DATA_W-1:0] i_wmem_data,

    output logic [BMEM_ADDR_W-1:0] o_bmem_addr,
    input  logic [BMEM_DATA_W-1:0] i_bmem_data,

    // Output & Status
    output logic signed [ACC_W-1:0] o_result [0:N_NEURON-1],
    output logic                    o_busy,
    output logic                    o_done
);

    localparam int N_GROUP_MAX = (N_NEURON + N_MAC - 1) / N_MAC;
    localparam int GIDX_W      = (N_GROUP_MAX > 1) ? $clog2(N_GROUP_MAX) : 1;

    // Total usable depth of the weight memory (per-group block of N_MAX slots).
    // Used only to guard the speculative "prefetch next" address so it never
    // walks off the end of the memory array.
    localparam int WMEM_DEPTH  = N_GROUP_MAX * N_MAX;

    typedef enum logic [2:0] {
        S_IDLE      = 3'b000,
        S_REQ_BIAS  = 3'b001,
        S_WAIT_BIAS = 3'b010,
        S_MAC_RUN   = 3'b011,
        S_STORE     = 3'b100,
        S_DONE      = 3'b101
    } state_t;

    state_t state, state_n;

    logic [GIDX_W-1:0]          group_idx;
    logic [$clog2(N_MAX+1)-1:0]  feat_idx;

    logic mac_clr;
    logic mac_en;

    logic signed [ACC_W-1:0] mac_out [0:N_MAC-1];

    logic [$clog2(N_NEURON+1)-1:0] base;
    assign base = group_idx * N_MAC;

    logic last_group;
    assign last_group = (base + N_MAC >= i_num_neurons);

    // FSM State Register
    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) state <= S_IDLE;
        else         state <= state_n;
    end

    // FSM Next State Logic
    always_comb begin
        state_n = state;
        case (state)
            S_IDLE:      if (i_start) state_n = S_REQ_BIAS;
            S_REQ_BIAS:  state_n = S_WAIT_BIAS;
            S_WAIT_BIAS: state_n = S_MAC_RUN;
            S_MAC_RUN:   if (feat_idx == i_num_inputs - 1) state_n = S_STORE;
            S_STORE:     state_n = last_group ? S_DONE : S_REQ_BIAS;
            S_DONE:      state_n = S_IDLE;
            default:     state_n = S_IDLE;
        endcase
    end

    assign mac_clr = (state == S_WAIT_BIAS);
    assign mac_en  = (state == S_MAC_RUN);

    // ------------------------------------------------------------------
    // BRAM 주소 / 프리패치 타이밍 (양쪽 메모리 모두 1클럭 read latency 가정)
    //
    // [BIAS] i_clr이 걸리는 시점(WAIT_BIAS -> MAC_RUN 전환 엣지)에 이미
    //   올바른 bias 값이 도착해 있어야 하므로, 주소는 그보다 "두 state 전"
    //   (그룹이 REQ_BIAS로 들어오기 직전, 즉 IDLE 또는 STORE)에 미리 던진다.
    //
    // [WEIGHT] index0은 REQ_BIAS 상태에서 미리 던져(WAIT_BIAS 동안 유효)
    //   MAC_RUN 진입 시점에 데이터가 준비되도록 하고, 이후로는 매 MAC_RUN
    //   사이클마다 "현재 쓰는 feat_idx보다 항상 1개 앞선" 주소를 유지한다
    //   (feat_idx+2, pre-edge 기준 - feat_idx가 다음 값으로 넘어간 뒤에도
    //   주소가 그보다 한 걸음 더 앞에 있도록).
    // ------------------------------------------------------------------
    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            group_idx   <= '0;
            feat_idx    <= '0;
            o_wmem_addr <= '0;
            o_bmem_addr <= '0;
            o_busy      <= 1'b0;
            o_done      <= 1'b0;
            for (int n = 0; n < N_NEURON; n++) o_result[n] <= '0;
        end else begin
            o_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (i_start) begin
                        group_idx   <= '0;
                        o_busy      <= 1'b1;
                        // group0의 bias를 미리 요청 (REQ_BIAS 기간 내내 유효하게)
                        o_bmem_addr <= '0;
                    end
                end

                S_REQ_BIAS: begin
                    feat_idx    <= '0;
                    // weight index0 프리패치: 이 값은 WAIT_BIAS 기간 동안
                    // 유효해져서, MAC_RUN 진입 시점에 데이터가 준비된다.
                    o_wmem_addr <= group_idx * N_MAX;
                end

                S_WAIT_BIAS: begin
                    // weight index1 프리패치 (다음 MAC_RUN 사이클을 위해).
                    // index0은 이미 REQ_BIAS에서 던져놨으므로 여기선 1개만
                    // 더 앞서가면 된다.
                    if ((group_idx * N_MAX + 1) < WMEM_DEPTH)
                        o_wmem_addr <= group_idx * N_MAX + 1;
                end

                S_MAC_RUN: begin
                    if (feat_idx < i_num_inputs - 1) begin
                        feat_idx <= feat_idx + 1'b1;
                        // 항상 "다음에 쓸 feat_idx"보다 한 스텝 더 앞선 주소를
                        // 요청해서 BRAM의 1클럭 read latency를 상쇄한다.
                        if ((group_idx * N_MAX + feat_idx + 2) < WMEM_DEPTH)
                            o_wmem_addr <= group_idx * N_MAX + feat_idx + 2;
                    end
                end

                S_STORE: begin
                    for (int g = 0; g < N_MAC; g++) begin
                        if (base + g < i_num_neurons)
                            o_result[base + g] <= mac_out[g];
                    end

                    if (last_group) begin
                        o_done <= 1'b1;
                    end else begin
                        group_idx   <= group_idx + 1'b1;
                        // 다음 그룹의 bias를 미리 요청 (그 그룹의 REQ_BIAS
                        // 기간 내내 유효하게 만들기 위해 한 state 앞서 던짐)
                        o_bmem_addr <= (group_idx + 1'b1);
                    end
                end

                S_DONE: begin
                    o_busy <= 1'b0;
                end

                default: ;
            endcase
        end
    end

    // MAC Units Instantiation
    genvar g;
    generate
        for (g = 0; g < N_MAC; g++) begin : gen_mac
            logic signed [WEIGHT_W-1:0] w_val;
            logic signed [BIAS_W-1:0]   b_val;

            assign w_val = $signed(i_wmem_data[g*WEIGHT_W +: WEIGHT_W]);
            assign b_val = $signed(i_bmem_data[g*BIAS_W   +: BIAS_W]);

            mac_unit #(
                .FEATURE_W(FEATURE_W),
                .WEIGHT_W (WEIGHT_W),
                .BIAS_W   (BIAS_W),
                .ACC_W    (ACC_W)
            ) u_mac (
                .i_clk    (i_clk),
                .i_rstn   (i_rstn),
                .i_clr    (mac_clr),
                .i_en     (mac_en),
                .i_feature(i_feature[feat_idx]),
                .i_weight (w_val),
                .i_bias   (b_val),
                .o_acc    (mac_out[g])
            );
        end
    endgenerate

endmodule
