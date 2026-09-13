`timescale 1ns/1ps
module tb_fpga_top;
    reg clk=0;
    always #5 clk=~clk;
    reg reset_n=0;
    wire tx, busy, done, error;
    fpga_top dut (.clk(clk), .reset_n(reset_n), .uart_rx_i(1'b1),
                  .uart_tx_o(tx), .busy(busy), .done(done), .error(error));

    task automatic reset_dut;
        #2 reset_n=0;
        #1;
        if (dut.rst_n !== 0) $fatal(1,"Reset assertion failed");
        repeat(3) @(negedge clk);
        reset_n=1;
        @(posedge clk); #1;
        if (dut.rst_n !== 0) $fatal(1,"Reset released too early");
        @(posedge clk); #1;
        if (dut.rst_n !== 1) $fatal(1,"Reset release failed");
        @(negedge clk);
    endtask
    task automatic check_done(input [15:0] expected, input integer count);
        wait(done===1); #1;
        if (busy !== 0) $fatal(1,"Busy must clear on completion");
        if (dut.u_packet_tx.captured !== expected) $fatal(1,"Result mismatch");
        if (dut.u_packet_tx.sends != count || dut.u_mlp_core.starts != count)
            $fatal(1,"Duplicate or missing transaction");
        @(posedge clk); #1;
        if (done !== 0) $fatal(1,"Done must be a one-cycle pulse");
    endtask

    initial begin
        // Watchdog prevents a deadlocked handshake from hanging simulation.
        #100000; $fatal(1,"Timeout");
    end
    initial begin
        reset_dut();
        // Low byte first: 1, 2, -3, 4, 5 -> mock signed sum = 9.
        dut.u_packet_rx.send_packet(40'h0504fd0201);
        wait(dut.tx_valid===1);
        repeat(5) begin
            @(posedge clk); #1;
            if (!dut.tx_valid || dut.result_hold !== 16'd9 || !busy)
                $fatal(1,"Result was not held during TX backpressure");
            if (dut.u_packet_tx.sends != 0) $fatal(1,"TX ignored ready");
        end
        @(negedge clk); dut.u_packet_tx.allow_ready=1;
        // Queue a second packet while busy; buffer must retain first features.
        fork
            dut.u_packet_rx.send_packet(40'hffffffffff);
            begin
                @(posedge clk); #1;
                if (dut.features !== 40'h0504fd0201)
                    $fatal(1,"Input buffer overwritten while busy");
                check_done(16'd9,1);
            end
        join
        check_done(16'hfffb,2); // five -1 values -> -5 (mock only)
        dut.u_packet_rx.inject_error();
        repeat(3) @(negedge clk);
        if (!error) $fatal(1,"Error was not latched");

        dut.u_packet_rx.send_packet(40'h0101010101);
        wait(dut.mlp_busy===1);
        reset_dut();
        if (busy || done || error) $fatal(1,"Reset did not abort work");
        repeat(12) @(negedge clk);
        if (done || dut.u_packet_tx.sends!=0) $fatal(1,"Stale result after reset");
        dut.u_packet_rx.send_packet(40'h0202020202);
        check_done(16'd10,1);

        // Reset while holding a result for a stalled transmitter.
        @(negedge clk); dut.u_packet_tx.allow_ready=0;
        dut.u_packet_rx.send_packet(40'h0303030303);
        wait(dut.tx_valid===1);
        reset_dut();
        if (dut.tx_valid || done || busy) $fatal(1,"Pending TX survived reset");
        $display("PASS: packet-level top integration (stub modules only)");
        $finish;
    end
endmodule
