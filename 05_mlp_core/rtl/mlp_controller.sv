`timescale 1ns / 1ps

module mlp_controller #(
    parameter int N_NEURONS_L1 = 16,
    parameter int N_NEURONS_L2 = 8,
    parameter int BUF_ADDR_W   = 4
)(
    input  logic                    i_clk,
    input  logic                    i_rstn,

    // TOP Controller Interface
    input  logic                    i_mlp_start,
    output logic                    o_mlp_busy,
    output logic                    o_mlp_done,

    // MLP Core Interface
    output logic [1:0]              o_layer_sel,
    output logic                    o_dense_start,
    input  logic                    i_dense_done,
    output logic                    o_buf_wr_en,
    output logic [BUF_ADDR_W-1:0]   o_buf_wr_addr,

    // SOH Result Register Interface
    output logic                    o_soh_reg_en
);

    typedef enum logic [3:0] {
        S_IDLE        = 4'd0,
        S_L1_START    = 4'd1,
        S_L1_WAIT     = 4'd2,
        S_L1_WRITE    = 4'd3,
        S_L2_START    = 4'd4,
        S_L2_WAIT     = 4'd5,
        S_L2_WRITE    = 4'd6,
        S_L3_START    = 4'd7,
        S_L3_WAIT     = 4'd8,
        S_REG_WRITE   = 4'd9,
        S_DONE        = 4'd10
    } state_t;

    state_t state;

    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            state         <= S_IDLE;
            o_mlp_busy    <= 1'b0;
            o_mlp_done    <= 1'b0;
            o_layer_sel   <= 2'd0;
            o_dense_start <= 1'b0;
            o_buf_wr_en   <= 1'b0;
            o_buf_wr_addr <= '0;
            o_soh_reg_en  <= 1'b0;
        end else begin
            case (state)
                // -------------------------------------------------------------
                // IDLE
                // -------------------------------------------------------------
                S_IDLE: begin
                    o_mlp_busy    <= 1'b0;
                    o_mlp_done    <= 1'b0;
                    o_dense_start <= 1'b0;
                    o_buf_wr_en   <= 1'b0;
                    o_buf_wr_addr <= '0;
                    o_soh_reg_en  <= 1'b0;
                    o_layer_sel   <= 2'd0;

                    if (i_mlp_start) begin
                        state         <= S_L1_START;
                        o_mlp_busy    <= 1'b1;
                        o_dense_start <= 1'b1; // S_L1_START 진입과 동시에 1클럭 펄스 인가
                        o_layer_sel   <= 2'd0;
                    end
                end

                // -------------------------------------------------------------
                // Layer 1
                // -------------------------------------------------------------
                S_L1_START: begin
                    o_dense_start <= 1'b0; // 1클럭 후 즉시 0
                    state         <= S_L1_WAIT;
                end

                S_L1_WAIT: begin
                    if (i_dense_done) begin
                        state         <= S_L1_WRITE;
                        o_buf_wr_en   <= 1'b1;
                        o_buf_wr_addr <= '0;
                    end
                end

                S_L1_WRITE: begin
                    if (o_buf_wr_addr >= N_NEURONS_L1 - 1) begin
                        state         <= S_L2_START;
                        o_buf_wr_en   <= 1'b0;
                        o_buf_wr_addr <= '0;
                        o_layer_sel   <= 2'd1; // L2로 레이어 전환
                        o_dense_start <= 1'b1; // L2에 정확히 1클럭 펄스 전달
                    end else begin
                        o_buf_wr_addr <= o_buf_wr_addr + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Layer 2
                // -------------------------------------------------------------
                S_L2_START: begin
                    o_dense_start <= 1'b0; // 1클럭 후 즉시 0
                    state         <= S_L2_WAIT;
                end

                S_L2_WAIT: begin
                    if (i_dense_done) begin
                        state         <= S_L2_WRITE;
                        o_buf_wr_en   <= 1'b1;
                        o_buf_wr_addr <= '0;
                    end
                end

                S_L2_WRITE: begin
                    if (o_buf_wr_addr >= N_NEURONS_L2 - 1) begin
                        state         <= S_L3_START;
                        o_buf_wr_en   <= 1'b0;
                        o_buf_wr_addr <= '0;
                        o_layer_sel   <= 2'd2; // L3로 레이어 전환
                        o_dense_start <= 1'b1; // L3에 정확히 1클럭 펄스 전달
                    end else begin
                        o_buf_wr_addr <= o_buf_wr_addr + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Layer 3 (Output Layer) & SOH Register
                // -------------------------------------------------------------
                S_L3_START: begin
                    o_dense_start <= 1'b0; // 1클럭 후 즉시 0
                    state         <= S_L3_WAIT;
                end

                S_L3_WAIT: begin
                    if (i_dense_done) begin
                        state        <= S_REG_WRITE;
                        o_soh_reg_en <= 1'b1; // 결과 래치용 1클럭 펄스
                    end
                end

                S_REG_WRITE: begin
                    o_soh_reg_en <= 1'b0;
                    state        <= S_DONE;
                    o_mlp_busy   <= 1'b0;
                    o_mlp_done   <= 1'b1; // 완료 알림 펄스
                end

                S_DONE: begin
                    o_mlp_done  <= 1'b0;
                    o_layer_sel <= 2'd0;
                    state       <= S_IDLE;
                end

                default: begin
                    state         <= S_IDLE;
                    o_mlp_busy    <= 1'b0;
                    o_mlp_done    <= 1'b0;
                    o_layer_sel   <= 2'd0;
                    o_dense_start <= 1'b0;
                    o_buf_wr_en   <= 1'b0;
                    o_buf_wr_addr <= '0;
                    o_soh_reg_en  <= 1'b0;
                end
            endcase
        end
    end

endmodule
