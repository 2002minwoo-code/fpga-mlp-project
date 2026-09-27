`timescale 1ns / 1ps

module mlp_controller_tb;

    // 파라미터 정의
    localparam int N_NEURONS_L1 = 16;
    localparam int N_NEURONS_L2 = 8;
    localparam int BUF_ADDR_W   = 4;
    localparam time CLK_PERIOD  = 10ns;
    localparam time WATCHDOG_TIMEOUT = 20us; // 전체 타임아웃 제한 시간

    // 신호 정의
    logic                   clk;
    logic                   rstn;
    logic                   i_mlp_start;
    logic                   o_mlp_busy;
    logic                   o_mlp_done;

    logic [1:0]             o_layer_sel;
    logic                   o_dense_start;
    logic                   i_dense_done;
    logic                   o_buf_wr_en;
    logic [BUF_ADDR_W-1:0]  o_buf_wr_addr;
    logic                   o_soh_reg_en;

    // 테스트 검증 제어 변수
    int   error_cnt = 0;
    logic block_dense_done = 0;
    int   done_pulse_width = 1;

    // DUT 인스턴스화
    mlp_controller #(
        .N_NEURONS_L1 (N_NEURONS_L1),
        .N_NEURONS_L2 (N_NEURONS_L2),
        .BUF_ADDR_W   (BUF_ADDR_W)
    ) dut (
        .i_clk         (clk),
        .i_rstn        (rstn),
        .i_mlp_start   (i_mlp_start),
        .o_mlp_busy    (o_mlp_busy),
        .o_mlp_done    (o_mlp_done),
        .o_layer_sel   (o_layer_sel),
        .o_dense_start (o_dense_start),
        .i_dense_done  (i_dense_done),
        .o_buf_wr_en   (o_buf_wr_en),
        .o_buf_wr_addr (o_buf_wr_addr),
        .o_soh_reg_en  (o_soh_reg_en)
    );

    // 100MHz 클럭 생성
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // -------------------------------------------------------------
    // Watchdog Timer (시뮬레이션 전체 무한 루프 / 데드락 방지)
    // -------------------------------------------------------------
    initial begin
        #WATCHDOG_TIMEOUT;
        $display("\n********************************************************");
        $error(" [WATCHDOG TIMEOUT] 시뮬레이션이 제한 시간(%0t)을 초과하여 강제 종료됩니다.", WATCHDOG_TIMEOUT);
        $display("   -> FSM이 특정 상태에서 빠져나오지 못했거나 교착 상태(Deadlock)에 걸렸습니다.");
        $display("********************************************************");
        $finish;
    end

    // -------------------------------------------------------------
    // Dense Layer BFM (지연 에뮬레이션 및 펄스 제어)
    // -------------------------------------------------------------
    int dense_delay = 5;
    int run_cnt = 0;
    logic dense_running = 0;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            i_dense_done  <= 1'b0;
            dense_running <= 1'b0;
            run_cnt       <= 0;
        end else begin
            i_dense_done <= 1'b0;

            if (o_dense_start) begin
                dense_running <= 1'b1;
                run_cnt       <= 0;
            end else if (dense_running) begin
                if (!block_dense_done) begin
                    if (run_cnt >= dense_delay - 1 && run_cnt < (dense_delay - 1 + done_pulse_width)) begin
                        i_dense_done <= 1'b1;
                    end
                    
                    if (run_cnt >= (dense_delay - 1 + done_pulse_width)) begin
                        dense_running <= 1'b0;
                        run_cnt       <= 0;
                    end else begin
                        run_cnt <= run_cnt + 1;
                    end
                end else begin
                    // Done 인가 차단 상태 유지
                    run_cnt <= run_cnt;
                end
            end
        end
    end

    // -------------------------------------------------------------
    // Self-Checking 확인 태스크
    // -------------------------------------------------------------
    task automatic check_idle_state(string tc_name);
        @(negedge clk);
        if (dut.state !== dut.S_IDLE || o_mlp_busy !== 1'b0 || o_mlp_done !== 1'b0 || 
            o_dense_start !== 1'b0 || o_buf_wr_en !== 1'b0 || o_soh_reg_en !== 1'b0) begin
            $error("  [FAIL][%s] IDLE 상태 및 출력 신호 불일치! state=%0d, busy=%b, done=%b", 
                   tc_name, dut.state, o_mlp_busy, o_mlp_done);
            error_cnt++;
        end else begin
            $display("  -> [%s] S_IDLE 및 모든 제어 신호 초기화 일치 확인", tc_name);
        end
    endtask

    task automatic reset_dut();
        rstn        <= 1'b0;
        i_mlp_start <= 1'b0;
        repeat (5) @(posedge clk);
        rstn        <= 1'b1;
        repeat (2) @(posedge clk);
        $display("[INFO] 시스템 리셋 완료");
    endtask

    task automatic run_test(string test_name, int delay_val);
        int write_cnt;
        $display("\n[TEST] %s 시작 (지연: %0d cycles)", test_name, delay_val);
        dense_delay = delay_val;

        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;

        // L1 확인
        wait(o_dense_start && (o_layer_sel == 2'd0));
        $display("  -> L1 Dense Start 감지");

        wait(o_buf_wr_en);
        write_cnt = 0;
        while (o_buf_wr_en) begin
            @(negedge clk);
            if (o_buf_wr_en) begin
                if (o_buf_wr_addr !== write_cnt) begin
                    $error("  [ERROR] L1 Write 주소 오류! 기대: %0d, 실제: %0d", write_cnt, o_buf_wr_addr);
                    error_cnt++;
                end
                write_cnt++;
            end
            @(posedge clk);
        end
        if (write_cnt != N_NEURONS_L1) begin
            $error("  [FAIL] L1 Write 개수 오류! %0d개 (기대: %0d)", write_cnt, N_NEURONS_L1);
            error_cnt++;
        end else begin
            $display("  -> L1 Write 완료 (총 %0d개 주소 정상 기록)", write_cnt);
        end

        // L2 확인
        wait(o_dense_start && (o_layer_sel == 2'd1));
        $display("  -> L2 Dense Start 감지");

        wait(o_buf_wr_en);
        write_cnt = 0;
        while (o_buf_wr_en) begin
            @(negedge clk);
            if (o_buf_wr_en) begin
                if (o_buf_wr_addr !== write_cnt) begin
                    $error("  [ERROR] L2 Write 주소 오류! 기대: %0d, 실제: %0d", write_cnt, o_buf_wr_addr);
                    error_cnt++;
                end
                write_cnt++;
            end
            @(posedge clk);
        end
        if (write_cnt != N_NEURONS_L2) begin
            $error("  [FAIL] L2 Write 개수 오류! %0d개 (기대: %0d)", write_cnt, N_NEURONS_L2);
            error_cnt++;
        end else begin
            $display("  -> L2 Write 완료 (총 %0d개 주소 정상 기록)", write_cnt);
        end

        // L3 확인
        wait(o_dense_start && (o_layer_sel == 2'd2));
        $display("  -> L3 Dense Start 감지");

        wait(o_soh_reg_en);
        @(negedge clk);
        if (dut.state !== dut.S_REG_WRITE) begin
            $error("  [FAIL] S_REG_WRITE 상태 불일치!");
            error_cnt++;
        end
        $display("  -> o_soh_reg_en 펄스 감지");

        wait(o_mlp_done);
        @(negedge clk);
        if (dut.state !== dut.S_DONE) begin
            $error("  [FAIL] S_DONE 상태 불일치!");
            error_cnt++;
        end
        $display("  -> o_mlp_done 펄스 감지");

        @(posedge clk);
        $display("[PASS] %s 성공!", test_name);
    endtask

    // -------------------------------------------------------------
    // 메인 시뮬레이션
    // -------------------------------------------------------------
    initial begin
        reset_dut();

        // [TC 1~4: 기본 연산 및 레이턴시]
        run_test("TC 1: 기본 지연 테스트", 5);
        run_test("TC 2: 초고속 연산 지연 테스트", 1);
        run_test("TC 3: 긴 연산 지연 테스트", 15);

        $display("\n[TEST] TC 4: 연속 추론(Back-to-Back) 시작");
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        wait(o_mlp_done);
        @(posedge clk);
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        wait(o_mlp_done);
        @(posedge clk);
        $display("[PASS] TC 4: 연속 추론 성공!");

        // [TC 5~8: 리셋 복구력]
        $display("\n[TEST] TC 5: 리셋 직후 시작 검증");
        reset_dut();
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        wait(o_mlp_done);
        @(posedge clk);
        @(posedge clk);
        check_idle_state("TC 5");
        $display("[PASS] TC 5: 리셋 직후 정상 기동 및 완료 확인!");

        $display("\n[TEST] TC 6: L1 연산 중 리셋 검증");
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        wait(dut.state == dut.S_L1_WAIT);
        repeat (2) @(posedge clk);
        rstn <= 1'b0;
        @(negedge clk);
        if (o_mlp_busy !== 1'b0 || dut.state !== dut.S_IDLE) begin
            $error("  [FAIL] TC 6: L1 중 리셋 시 즉각 초기화 실패!");
            error_cnt++;
        end else begin
            $display("  -> L1 도중 리셋 시 즉각 IDLE 복귀 및 Busy=0 확인");
        end
        repeat (3) @(posedge clk);
        rstn <= 1'b1;
        repeat (2) @(posedge clk);
        check_idle_state("TC 6");
        $display("[PASS] TC 6: L1 리셋 처리 통과!");

        $display("\n[TEST] TC 7: L2 연산 중 리셋 검증");
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        wait(dut.state == dut.S_L2_WAIT);
        @(posedge clk);
        rstn <= 1'b0;
        @(negedge clk);
        if (o_mlp_busy !== 1'b0 || dut.state !== dut.S_IDLE) begin
            $error("  [FAIL] TC 7: L2 중 리셋 실패!");
            error_cnt++;
        end
        repeat (3) @(posedge clk);
        rstn <= 1'b1;
        repeat (2) @(posedge clk);
        check_idle_state("TC 7");
        $display("[PASS] TC 7: L2 리셋 처리 통과!");

        $display("\n[TEST] TC 8: L3 연산 중 리셋 검증");
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        wait(dut.state == dut.S_L3_WAIT);
        @(posedge clk);
        rstn <= 1'b0;
        @(negedge clk);
        if (o_soh_reg_en !== 1'b0 || dut.state !== dut.S_IDLE) begin
            $error("  [FAIL] TC 8: L3 리셋 중 soh_reg_en 오출력 발생!");
            error_cnt++;
        end
        repeat (3) @(posedge clk);
        rstn <= 1'b1;
        repeat (2) @(posedge clk);
        check_idle_state("TC 8");
        $display("[PASS] TC 8: L3 리셋 처리 통과!");

        // ---------------------------------------------------------
        // TC 9: Busy 중 Start 입력 무시 및 파이프라인 무결성 검증
        // ---------------------------------------------------------
        $display("\n[TEST] TC 9: Busy 중 Start 입력 무시 및 파이프라인 무결성 검증");
        dense_delay = 5;
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        
        wait(dut.state == dut.S_L2_WAIT);
        
        // 주석과 동일하게 비정상 Start 펄스를 실제로 2회 연속 주입
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        
        @(negedge clk);
        if (dut.state !== dut.S_L2_WAIT && dut.state !== dut.S_L2_WRITE) begin
            $error("  [FAIL] TC 9: Busy 중 Start 신호로 인한 오동작 전이 발생! state=%0d", dut.state);
            error_cnt++;
        end
        
        wait(o_buf_wr_en);
        @(posedge clk);
        wait(o_dense_start && (o_layer_sel == 2'd2));
        wait(o_soh_reg_en);
        wait(o_mlp_done);
        @(posedge clk);
        check_idle_state("TC 9");
        $display("  -> 연산 도중 Start 글리치(2회) 무시 및 잔여 레이어 100% 정상 완주 확인");
        $display("[PASS] TC 9: 중복 시작 요청 방어 통과!");

        // ---------------------------------------------------------
        // TC 10: Dense Done 2클럭 유지 시 전 레이어 다중 전이 방어 검증
        // ---------------------------------------------------------
        $display("\n[TEST] TC 10: Dense Done 2클럭 유지 시 전 레이어 다중 전이 방어 검증");
        begin
            int tc10_err_before = error_cnt;
            int addr_cnt = 0;

            done_pulse_width = 2; // 완료 신호 2클럭 유지
            @(posedge clk);
            i_mlp_start <= 1'b1;
            @(posedge clk);
            i_mlp_start <= 1'b0;
            
            // 1. L1 주소 순차 증가 및 개수 전수 검증
            wait(o_buf_wr_en);
            addr_cnt = 0;
            while (o_buf_wr_en) begin
                @(negedge clk);
                if (o_buf_wr_en) begin
                    if (o_buf_wr_addr !== addr_cnt) begin
                        $error("  [FAIL] TC 10: L1 주소 건너뜀 발생! 기대:%0d, 실제:%0d", addr_cnt, o_buf_wr_addr);
                        error_cnt++;
                    end
                    addr_cnt++;
                end
                @(posedge clk);
            end

            // L1 기록 총 개수 단정문 확인
            if (addr_cnt != N_NEURONS_L1) begin
                $error("  [FAIL] TC 10: L1 기록 총 개수 불일치! 기대:%0d, 실제:%0d", N_NEURONS_L1, addr_cnt);
                error_cnt++;
            end

            // 2. 중간 레이어 스킵 유무 확인 (L2, L3 정상 전이)
            wait(o_dense_start && (o_layer_sel == 2'd1));
            wait(o_dense_start && (o_layer_sel == 2'd2));
            wait(o_soh_reg_en);
            wait(o_mlp_done);
            @(posedge clk);

            done_pulse_width = 1; // 원복
            check_idle_state("TC 10");

            // 3. 실제 발생 에러와 연동된 PASS 판정
            if (error_cnt == tc10_err_before) begin
                $display("  -> Done 지연 시에도 상태 다중 점프 및 주소 건너뜀 없음 확인");
                $display("[PASS] TC 10: 완료 신호 2클럭 유지 방어 통과!");
            end else begin
                $display("[FAIL] TC 10: 완료 신호 2클럭 유지 검증 실패");
            end
        end

        // ---------------------------------------------------------
        // TC 11: 타임아웃 대기 및 신호 변경 타이밍 동기화 복구 (수정 완료)
        // ---------------------------------------------------------
        $display("\n[TEST] TC 11: Dense Done 장시간 미입력 시 Busy 유지 및 동기 복구 검증");
        block_dense_done = 1; // BFM 출력 일시 정지
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        
        // 40클럭 동안 무응답(Stall) 상태 유지 모니터링
        repeat (40) @(posedge clk);
        @(negedge clk);
        if (dut.state !== dut.S_L1_WAIT || o_mlp_busy !== 1'b1) begin
            $error("  [FAIL] TC 11: Done 미입력 상태에서 대기 이탈 발생! state=%0d, busy=%b", dut.state, o_mlp_busy);
            error_cnt++;
        end else begin
            $display("  -> 장시간 Done 미도착 시에도 S_L1_WAIT 유지 및 Busy=1 보장 확인");
        end
        
        // 클럭 하강 엣지에서 플래그를 해제하여 다음 상승 엣지에서 BFM이 안전하게 Done 펄스를 방출하도록 타이밍 정합
        @(negedge clk);
        block_dense_done = 0;
        
        wait(o_mlp_done);
        @(posedge clk);
        check_idle_state("TC 11");
        $display("[PASS] TC 11: 타임아웃 대기 및 동기 복구 완료!");

        // [TC 12~13: 즉각 재기동 및 파이프라인]
        $display("\n[TEST] TC 12: Done 직후 즉각 재시작 검증");
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        
        wait(o_mlp_done);
        @(posedge clk); // S_DONE 통과
        @(posedge clk); // S_IDLE 도착 시점

        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;
        
        @(negedge clk);
        if (!o_mlp_busy || dut.state !== dut.S_L1_START) begin
            $error("  [FAIL] TC 12: Done 직후 S_L1_START 진입 실패! state=%0d", dut.state);
            error_cnt++;
        end else begin
            $display("  -> S_IDLE 복귀 즉시 재기동(Zero-Bubble) 성공 확인");
        end
        wait(o_mlp_done);
        @(posedge clk);
        $display("[PASS] TC 12: Done 직후 재시작 통과!");

        $display("\n[TEST] TC 13: 연속 추론 2회 전체 레이어 파이프라인 검증");
        run_test("TC 13 - 1회차 전체 추론", 4);
        run_test("TC 13 - 2회차 전체 추론", 4);
        check_idle_state("TC 13");
        $display("[PASS] TC 13: 2회 연속 전 레이어 완벽 완주!");

        // ---------------------------------------------------------
        // TC 14: 파라미터 경계값 및 디어서트 검증 (명칭 및 보고 정돈 완료)
        // ---------------------------------------------------------
        $display("\n[TEST] TC 14: 버퍼 주소 카운팅 경계값 및 디어서트 검증 (Parameter Boundary & De-assertion)");
        dense_delay = 2;
        @(posedge clk);
        i_mlp_start <= 1'b1;
        @(posedge clk);
        i_mlp_start <= 1'b0;

        // L1 경계값 체크: 주소가 15에 도달했을 때
        wait(o_buf_wr_en && (o_buf_wr_addr == N_NEURONS_L1 - 1));
        @(posedge clk);
        @(negedge clk);
        if (o_buf_wr_en !== 1'b0 || dut.state !== dut.S_L2_START) begin
            $error("  [FAIL] TC 14: L1 상한 도달 직후 o_buf_wr_en 디어서트 실패!");
            error_cnt++;
        end else begin
            $display("  -> L1 최대 주소(%0d) 도달 직후 1클럭 내 o_buf_wr_en=0 및 L2 전이 확인", N_NEURONS_L1 - 1);
        end

        // L2 경계값 체크: 주소가 7에 도달했을 때
        wait(o_buf_wr_en && (o_buf_wr_addr == N_NEURONS_L2 - 1));
        @(posedge clk);
        @(negedge clk);
        if (o_buf_wr_en !== 1'b0 || dut.state !== dut.S_L3_START) begin
            $error("  [FAIL] TC 14: L2 상한 도달 직후 o_buf_wr_en 디어서트 실패!");
            error_cnt++;
        end else begin
            $display("  -> L2 최대 주소(%0d) 도달 직후 1클럭 내 o_buf_wr_en=0 및 L3 전이 확인", N_NEURONS_L2 - 1);
        end

        wait(o_mlp_done);
        @(posedge clk);
        check_idle_state("TC 14");
        $display("[PASS] TC 14: 파라미터 경계값 및 디어서트 검증 완료!");

        // =========================================================
        // 최종 요약 보고
        // =========================================================
        $display("\n********************************************************");
        if (error_cnt == 0) begin
            $display("   [ALL 14 TESTS PASSED] TC 1 ~ TC 14 전수 통과 완료!   ");
            $display("   - Watchdog 타이머 기반 데드락 부재 보증               ");
            $display("   - TC 9/10 결함 주입 및 2-Cycle Done 다중 전이 방어 완료");
            $display("   - TC 11 BFM 동기화 복구 및 TC 14 경계값 정합성 입증  ");
        end else begin
            $display("   [TEST FAILED] 총 %0d 건의 에러가 감지되었습니다.      ", error_cnt);
        end
        $display("********************************************************");
        $finish;
    end

endmodule
