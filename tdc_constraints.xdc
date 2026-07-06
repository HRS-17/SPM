# =============================================================
# Starter constraints for the TDL-based TDC (PYNQ-Z2, xc7z020clg400-1)
# Adjust net/instance names to match your actual synthesized
# hierarchy (check Vivado's schematic / Tcl console names).
# =============================================================

## ---- Clock (example: 100 MHz from PS FCLK0) ----
create_clock -name pl_clk -period 10.000 [get_ports clk]

## ---- False paths: the TDL relies on raw logic/routing delay,
##      not on a real synchronous timing path. Vivado cannot
##      (and should not) try to "close timing" through it.
set_false_path -to [get_pins -hier -filter {NAME =~ *tap_ff*/D}]

## ---- Keep the carry chain from being optimized/retimed/merged ----
set_property DONT_TOUCH TRUE [get_cells -hier -filter {NAME =~ *carry4_inst*}]
set_property DONT_TOUCH TRUE [get_cells -hier -filter {NAME =~ *tap_ff*}]

## ---- Pin the start of each TDL chain to a fixed slice column so
##      re-implementation gives reproducible tap delays (important
##      for your calibration table to stay valid across rebuilds).
##      Replace SLICE_X#Y# with real coordinates from Device view
##      after a first placement run.
# set_property LOC SLICE_X50Y50  [get_cells u_tdl_start/carry4_gen[0].carry4_inst]
# set_property LOC SLICE_X60Y50  [get_cells u_tdl_stop/carry4_gen[0].carry4_inst]

## ---- Optional: constrain the whole TDL into one column via a Pblock
##      so placer doesn't spread carry4 elements across clock regions.
# create_pblock pblock_tdl_start
# add_cells_to_pblock [get_pblocks pblock_tdl_start] [get_cells u_tdl_start/*]
# resize_pblock [get_pblocks pblock_tdl_start] -add {SLICE_X48Y40:SLICE_X48Y104}

## ---- I/O timing for async start/stop pins (mark as pseudo-async) ----
set_false_path -from [get_ports start_in]
set_false_path -from [get_ports stop_in]

## ---- Physical pin assignments (edit to match your PMOD/GPIO wiring) ----
# set_property PACKAGE_PIN Y18 [get_ports start_in]
# set_property IOSTANDARD LVCMOS33 [get_ports start_in]
# set_property PACKAGE_PIN Y19 [get_ports stop_in]
# set_property IOSTANDARD LVCMOS33 [get_ports stop_in]
