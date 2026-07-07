`timescale 1ns/1ps

module tdc_top_tb;

    reg  clk = 0;
    reg  rst = 1;
    reg  start_in = 0;
    reg  stop_in  = 0;

    wire [15:0] coarse_count;
    wire [6:0]  fine_start_code;
    wire [6:0]  fine_stop_code;
    wire        meas_done;

    always #5 clk = ~clk;

    tdc_top #(
        .NUM_TAPS(64), .OUT_WIDTH(7), .CNT_WIDTH(16)
    ) dut (
        .clk(clk), .rst(rst),
        .start_in(start_in), .stop_in(stop_in),
        .coarse_count(coarse_count),
        .fine_start_code(fine_start_code),
        .fine_stop_code(fine_stop_code),
        .meas_done(meas_done)
    );

    initial begin
        rst = 1;
        #20;
        rst = 0;
        #20;

        start_in = 1;
        #12;
        start_in = 0;

        #33;

        stop_in = 1;
        #12;
        stop_in = 0;

        #50;

        $display("coarse_count     = %0d", coarse_count);
        $display("fine_start_code  = %0d", fine_start_code);
        $display("fine_stop_code   = %0d", fine_stop_code);
        $display("meas_done        = %0d", meas_done);

        #20 $finish;
    end

endmodule
