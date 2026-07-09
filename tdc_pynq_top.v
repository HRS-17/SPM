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

    wire [NUM_TAPS-1:0] thermo_start;
    wire [NUM_TAPS-1:0] thermo_stop;

    tdl_chain #(.NUM_TAPS(NUM_TAPS)) u_tdl_start (
        .clk(clk), .start(start_in), .thermo_code(thermo_start)
    );

    tdl_chain #(.NUM_TAPS(NUM_TAPS)) u_tdl_stop (
        .clk(clk), .start(stop_in), .thermo_code(thermo_stop)
    );

    thermo_encoder #(.NUM_TAPS(NUM_TAPS), .OUT_WIDTH(OUT_WIDTH)) u_enc_start (
        .thermo_code(thermo_start), .fine_code(fine_start_code)
    );

    thermo_encoder #(.NUM_TAPS(NUM_TAPS), .OUT_WIDTH(OUT_WIDTH)) u_enc_stop (
        .thermo_code(thermo_stop), .fine_code(fine_stop_code)
    );

    coarse_counter #(.WIDTH(CNT_WIDTH)) u_coarse (
        .clk(clk), .rst(rst),
        .start(start_in), .stop(stop_in),
        .coarse_count(coarse_count),
        .done(meas_done)
    );

endmodule
