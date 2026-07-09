`timescale 1ns / 1ps

// =============================================================
// Top Level TDC Module
// =============================================================
module tdc_top #(
    parameter NUM_TAPS   = 256,
    parameter OUT_WIDTH  = 9,
    parameter CNT_WIDTH  = 16
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     start_in,
    input  wire                     stop_in,
    output reg  [CNT_WIDTH-1:0]     coarse_count,
    output wire [OUT_WIDTH-1:0]     fine_start_code,
    output wire [OUT_WIDTH-1:0]     fine_stop_code,
    output wire                     meas_done
);

    wire start_captured, stop_captured;
    wire start_sync, stop_sync;

    fine_capture #(
        .NUM_TAPS(NUM_TAPS), 
        .OUT_WIDTH(OUT_WIDTH)
    ) u_fine_start (
        .clk(clk), 
        .rst(rst), 
        .trigger(start_in),
        .fine_code_held(fine_start_code), 
        .captured(start_captured),
        .trigger_sync(start_sync)
    );

    fine_capture #(
        .NUM_TAPS(NUM_TAPS), 
        .OUT_WIDTH(OUT_WIDTH)
    ) u_fine_stop (
        .clk(clk), 
        .rst(rst), 
        .trigger(stop_in),
        .fine_code_held(fine_stop_code), 
        .captured(stop_captured),
        .trigger_sync(stop_sync)
    );

    // Synchronized Coarse Counter
    always @(posedge clk) begin
        if (rst) begin
            coarse_count <= {CNT_WIDTH{1'b0}};
        end else if (start_sync && !stop_sync) begin
            coarse_count <= coarse_count + 1'b1;
        end
    end
    
    assign meas_done = stop_captured;

endmodule

// =============================================================
// Fine Capture Pipeline
// =============================================================
module fine_capture #(
    parameter NUM_TAPS  = 256,
    parameter OUT_WIDTH = 9
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  trigger,
    output reg  [OUT_WIDTH-1:0]  fine_code_held,
    output reg                   captured,
    output wire                  trigger_sync
);

    wire [NUM_TAPS-1:0] thermo_live;
    
    tdl_chain #(.NUM_TAPS(NUM_TAPS)) u_tdl (
        .clk(clk), .start(trigger), .thermo_code(thermo_live)
    );

    // PIPELINE STAGE 1: Resolve Metastability
    reg [NUM_TAPS-1:0] thermo_p1;
    reg sync_p1, sync_p2, sync_p3;
    
    always @(posedge clk) begin
        thermo_p1 <= thermo_live; 
        
        // Tap 0 CDC Trick
        sync_p1 <= thermo_live[0]; 
        sync_p2 <= sync_p1;
        sync_p3 <= sync_p2;
    end

    wire [OUT_WIDTH-1:0] fine_encoded;
    thermo_encoder #(.NUM_TAPS(NUM_TAPS), .OUT_WIDTH(OUT_WIDTH)) u_enc (
        .thermo_code(thermo_p1), .fine_code(fine_encoded)
    );

    wire capture_pulse = sync_p2 & ~sync_p3;
    assign trigger_sync = sync_p2;

    // Hold Register
    always @(posedge clk) begin
        if (rst) begin
            fine_code_held <= {OUT_WIDTH{1'b0}};
            captured       <= 1'b0;
        end else if (capture_pulse && !captured) begin
            fine_code_held <= fine_encoded; 
            captured       <= 1'b1;
        end
    end
endmodule

// =============================================================
// Tapped Delay Line (CARRY4 Array)
// =============================================================
module tdl_chain #(
    parameter NUM_TAPS = 256
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
            FDRE tap_ff (
                .Q   (thermo_code[i]),
                .C   (clk),
                .CE  (1'b1),
                .R   (1'b0),
                .D   (carry_chain[i+1])
            );
        end
    endgenerate
endmodule

// =============================================================
// Thermometer to Binary Encoder (Popcount)
// =============================================================
module thermo_encoder #(
    parameter NUM_TAPS  = 256,
    parameter OUT_WIDTH = 9
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
