// =============================================================
// dense_layer.sv (올림 나눗셈 버그 수정 및 포트 규격 반영)
// =============================================================
`timescale 1ns / 1ps

module dense_layer #(
    parameter int FEATURE_W = 8,
    parameter int WEIGHT_W  = 8,
    parameter int BIAS_W    = 32,
    parameter int N_NEURON  = 16,
    parameter int N_MAX     = 16,
    parameter int ACC_W     = 32,
    parameter int N_MAC     = 8,

    // 올림 나눗셈 적용: (N_NEURON + N_MAC - 1) / N_MAC
    parameter int WMEM_DATA_W = N_MAC * WEIGHT_W,
    parameter int BMEM_DATA_W = N_MAC * BIAS_W,
    parameter int WMEM_ADDR_W = $clog2(((N_NEURON + N_MAC - 1) / N_MAC) * N_MAX),
    parameter int BMEM_ADDR_W = (((N_NEURON + N_MAC - 1) / N_MAC) > 1) ? 
                                $clog2((N_NEURON + N_MAC - 1) / N_MAC) : 1
)(
    // System Signals
    input  logic i_clk,
    input  logic i_rstn,

    // Control & Config
    input  logic                         i_start,
    input  logic [$clog2(N_NEURON+1)-1:0] i_num_neurons,
    input  logic [$clog2(N_MAX+1)-1:0]    i_num_inputs,

    // Feature Input
    input  logic signed [FEATURE_W-1:0] i_feature [0:N_MAX-1],

    // BRAM Interfaces
    output logic [WMEM_ADDR_W-1:0] o_wmem_addr,
    input  logic [WMEM_DATA_W-1:0] i_wmem_data,

    output logic [BMEM_ADDR_W-1:0] o_bmem_addr,
    input  logic [BMEM_DATA_W-1:0] i_bmem_data,

    // Output & Status
    output logic signed [ACC_W-1:0] o_result [0:N_NEURON-1],
    output logic                    o_busy,
    output logic                    o_done
);

    // [수정] 그룹 수 올림 나눗셈 계산
    localparam int N_GROUP_MAX = (N_NEURON + N_MAC - 1) / N_MAC;
    localparam int GIDX_W      = (N_GROUP_MAX > 1) ? $clog2(N_GROUP_MAX) : 1;

    typedef enum logic [2:0] {
        S_IDLE      = 3'b000,
        S_REQ_BIAS  = 3'b001,
        S_WAIT_DATA = 3'b010,
        S_MAC_RUN   = 3'b011,
        S_STORE     = 3'b100,
        S_DONE      = 3'b101
    } state_t;

    state_t state, state_n;

    logic [GIDX_W-1:0]          group_idx;
    logic [$clog2(N_MAX+1)-1:0]  feat_idx;

    // MAC 제어 신호
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
            S_REQ_BIAS:  state_n = S_WAIT_DATA;
            S_WAIT_DATA: state_n = S_MAC_RUN;
            S_MAC_RUN:   if (feat_idx == i_num_inputs - 1) state_n = S_STORE;
            S_STORE:     state_n = last_group ? S_DONE : S_REQ_BIAS;
            S_DONE:      state_n = S_IDLE;
            default:     state_n = S_IDLE;
        endcase
    end

    assign mac_clr = (state == S_MAC_RUN) && (feat_idx == 0);
    assign mac_en  = (state == S_MAC_RUN) && (feat_idx > 0) && (feat_idx < i_num_inputs);

    // BRAM 주소 제어 및 인덱스 카운터
    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            group_idx   <= '0;
            feat_idx    <= '0;
            o_wmem_addr <= '0;
            o_bmem_addr <= '0;
            o_busy      <= 1'b0;
            o_done      <= 1'b0;
        end else begin
            o_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (i_start) begin
                        group_idx <= '0;
                        o_busy    <= 1'b1;
                    end
                end

                S_REQ_BIAS: begin
                    o_bmem_addr <= group_idx[BMEM_ADDR_W-1:0];
                    o_wmem_addr <= (group_idx * i_num_inputs) + '0;
                    feat_idx    <= '0;
                end

                S_WAIT_DATA: begin
                    if (i_num_inputs > 1)
                        o_wmem_addr <= (group_idx * i_num_inputs) + 1'b1;
                end

                S_MAC_RUN: begin
                    if (feat_idx < i_num_inputs - 1) begin
                        feat_idx    <= feat_idx + 1'b1;
                        o_wmem_addr <= (group_idx * i_num_inputs) + (feat_idx + 2'd2);
                    end else begin
                        feat_idx    <= feat_idx + 1'b1;
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
                        group_idx <= group_idx + 1'b1;
                    end
                end

                S_DONE: begin
                    o_busy <= 1'b0;
                end

                default: ;
            endcase
        end
    end

    // MAC 유닛 8개 인스턴스화
    genvar g;
    generate
        for (g = 0; g < N_MAC; g++) begin : gen_mac
            logic signed [WEIGHT_W-1:0] w_val;
            logic signed [BIAS_W-1:0]   b_val;

            assign w_val = $signed(i_wmem_data[g*WEIGHT_W +: WEIGHT_W]);
            assign b_val = $signed(i_bmem_data[g*BIAS_W   +: BIAS_W]);

            mac_unit #(
                .FEATURE_W(FEATURE_W),
                .WEIGHT_W(WEIGHT_W),
                .BIAS_W(BIAS_W),
                .ACC_W(ACC_W)
            ) u_mac (
                .i_clk     (i_clk),
                .i_rstn    (i_rstn),
                .i_clr     (mac_clr),
                .i_en      (mac_en),
                .i_b_data  (b_val),
                .i_f_data  (i_feature[feat_idx]),
                .i_w_data  (w_val),
                .o_acc_data(mac_out[g])
            );
        end
    endgenerate

endmodule
