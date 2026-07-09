// =============================================================
// Single-Chain Tapped Delay Line (TDL) TDC for PYNQ-Z2 (xc7z020)
// Target resolution: 1-2 ns (CARRY4 native tap ~20-90ps, so we
// have generous margin -- design is intentionally oversampled).
//
// NUM_TAPS = 256 so the chain's total span (256 * ~20-90ps =
// roughly 5-23ns depending on real silicon delay) covers at
// least one full clk period (e.g. 10ns @ 100MHz). Fewer taps
// would leave a "blind" region late in each clock period where
// the pulse runs off the end of the chain and the fine code
// saturates at NUM_TAPS, silently losing resolution for edges
// landing there. Adjust NUM_TAPS if you change clk frequency.
// =============================================================

// -------------------------------------------------------------
// 1. Fine TDL chain built from CARRY4 primitives.
//    START propagates asynchronously down the carry chain; the
//    system clock samples every tap on its rising edge, giving
//    a thermometer code that encodes how far the edge traveled
//    before the clock arrived.
// -------------------------------------------------------------
module tdl_chain #(
    parameter NUM_TAPS = 256   // must be multiple of 4; covers ~10ns clock period at ~40ps/tap
)(
    input  wire                  clk,
    input  wire                  start,
    output wire [NUM_TAPS-1:0]   thermo_code
);

    (* DONT_TOUCH = "TRUE" *)
    wire [NUM_TAPS:0] carry_chain;
    assign carry_chain[0] = start;

    genvar i;
    generate
        for (i = 0; i < NUM_TAPS/4; i = i + 1) begin : carry4_gen
            (* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "TRUE" *)
            CARRY4 carry4_inst (
                .CO(carry_chain[4*i+4 : 4*i+1]),
                .O(),
                .CI(carry_chain[4*i]),
                .CYINIT(1'b0),
                .DI(4'b0000),
                .S(4'b1111)
            );
        end
    endgenerate

    generate
        for (i = 0; i < NUM_TAPS; i = i + 1) begin : reg_gen
            (* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE" *)
            FDCE tap_ff (
                .Q   (thermo_code[i]),
                .C   (clk),
                .CE  (1'b1),
                .CLR (1'b0),
                .D   (carry_chain[i+1])
            );
        end
    endgenerate

endmodule


// -------------------------------------------------------------
// 2. Thermometer -> binary encoder using popcount.
//    Popcount is naturally tolerant of single-bit "bubbles"
//    caused by metastability near the sampling transition,
//    unlike a plain priority encoder.
// -------------------------------------------------------------
module thermo_encoder #(
    parameter NUM_TAPS  = 256,
    parameter OUT_WIDTH = 9      // ceil(log2(NUM_TAPS+1))
)(
    input  wire [NUM_TAPS-1:0]   thermo_code,
    output reg  [OUT_WIDTH-1:0]  fine_code
);
    integer j;
    always @(*) begin
        fine_code = {OUT_WIDTH{1'b0}};
        for (j = 0; j < NUM_TAPS; j = j + 1)
            fine_code = fine_code + thermo_code[j];
    end
endmodule


// -------------------------------------------------------------
// 3. Coarse counter: counts full clk periods between start/stop.
// -------------------------------------------------------------
module coarse_counter #(
    parameter WIDTH = 16
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire              stop,
    output reg  [WIDTH-1:0]  coarse_count,
    output reg               done
);
    reg counting;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            coarse_count <= {WIDTH{1'b0}};
            counting     <= 1'b0;
            done         <= 1'b0;
        end else begin
            if (start && !counting) begin
                counting     <= 1'b1;
                coarse_count <= {WIDTH{1'b0}};
                done         <= 1'b0;
            end else if (stop && counting) begin
                counting <= 1'b0;
                done     <= 1'b1;
            end else if (counting) begin
                coarse_count <= coarse_count + 1'b1;
            end
        end
    end
endmodule


// -------------------------------------------------------------
// 3b. Fine capture: wraps tdl_chain + thermo_encoder and adds
//     "capture once, then hold" behavior.
//
//     Without this, the tap flip-flops keep re-sampling every
//     single clock cycle -- if the trigger (start_in/stop_in)
//     stays high for multiple clocks (as it will, since it's
//     driven from a software-written AXI register), every clock
//     edge after the pulse fully saturates the chain reads all-1s,
//     and once the trigger drops low again the chain reverts to
//     all-0s. Whatever meaningful code appeared on the very first
//     clock edge gets overwritten by the next edge before software
//     ever gets a chance to read it.
//
//     Fix: a 2-flip-flop edge detector finds the exact one clock
//     cycle where trigger just transitioned low->high, and a
//     separate hold register captures the fine code only during
//     that cycle, then freezes (ignores further updates) until
//     "rst" re-arms it for the next measurement.
// -------------------------------------------------------------
module fine_capture #(
    parameter NUM_TAPS  = 256,
    parameter OUT_WIDTH = 9
)(
    input  wire                  clk,
    input  wire                  rst,       // re-arm for next measurement
    input  wire                  trigger,   // start_in or stop_in
    output wire [OUT_WIDTH-1:0]  fine_code_held,
    output wire                  captured
);

    wire [NUM_TAPS-1:0]  thermo_code;
    wire [OUT_WIDTH-1:0] fine_code_live;

    tdl_chain #(.NUM_TAPS(NUM_TAPS)) u_tdl (
        .clk(clk), .start(trigger), .thermo_code(thermo_code)
    );

    thermo_encoder #(.NUM_TAPS(NUM_TAPS), .OUT_WIDTH(OUT_WIDTH)) u_enc (
        .thermo_code(thermo_code), .fine_code(fine_code_live)
    );

    // 2-stage edge detector on the raw trigger
    reg trig_d1, trig_d2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            trig_d1 <= 1'b0;
            trig_d2 <= 1'b0;
        end else begin
            trig_d1 <= trigger;
            trig_d2 <= trig_d1;
        end
    end
    wire capture_pulse = trig_d1 & ~trig_d2;  // high for exactly 1 cycle

    // Hold register: updates only during capture_pulse, then freezes
    reg [OUT_WIDTH-1:0] fine_code_reg;
    reg                 captured_reg;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fine_code_reg <= {OUT_WIDTH{1'b0}};
            captured_reg  <= 1'b0;
        end else if (capture_pulse && !captured_reg) begin
            fine_code_reg <= fine_code_live;
            captured_reg  <= 1'b1;
        end
    end

    assign fine_code_held = fine_code_reg;
    assign captured       = captured_reg;

endmodule


// -------------------------------------------------------------
// 4. Top-level TDC datapath.
//    Two TDL chains (start-fine, stop-fine) let you resolve the
//    sub-clock-period offset of BOTH edges; software combines
//    coarse_count and the two fine codes (after calibration)
//    into the final time interval.
//
//    Wrap this module's ports into an AXI4-Lite shell (via
//    Vivado's "Create and Package New IP" wizard) to expose
//    coarse_count / fine_start_code / fine_stop_code / status
//    as memory-mapped registers for PYNQ.
// -------------------------------------------------------------
module tdc_top #(
    parameter NUM_TAPS   = 256,
    parameter OUT_WIDTH  = 9,
    parameter CNT_WIDTH  = 16
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     start_in,   // async edges
    input  wire                     stop_in,
    output wire [CNT_WIDTH-1:0]     coarse_count,
    output wire [OUT_WIDTH-1:0]     fine_start_code,
    output wire [OUT_WIDTH-1:0]     fine_stop_code,
    output wire                     meas_done
);

    wire start_captured, stop_captured;

    fine_capture #(.NUM_TAPS(NUM_TAPS), .OUT_WIDTH(OUT_WIDTH)) u_fine_start (
        .clk(clk), .rst(rst), .trigger(start_in),
        .fine_code_held(fine_start_code), .captured(start_captured)
    );

    fine_capture #(.NUM_TAPS(NUM_TAPS), .OUT_WIDTH(OUT_WIDTH)) u_fine_stop (
        .clk(clk), .rst(rst), .trigger(stop_in),
        .fine_code_held(fine_stop_code), .captured(stop_captured)
    );

    coarse_counter #(.WIDTH(CNT_WIDTH)) u_coarse (
        .clk(clk), .rst(rst),
        .start(start_in), .stop(stop_in),
        .coarse_count(coarse_count),
        .done(meas_done)
    );

endmodule
