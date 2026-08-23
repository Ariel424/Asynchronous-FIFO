// ============================================================================
// 0. INTERFACE DEFINITION
// ============================================================================
interface my_interface (
  input logic wclk,
  input logic rclk
);
  logic       wreset;
  logic       rreset;
  logic       write;
  logic [7:0] data_in;
  logic       full;
  
  logic       read;
  logic [7:0] data_out;
  logic       empty;

  logic [1:0] w_freq_mode;
  logic [1:0] r_freq_mode;

  // Clocking Blocks
  clocking w_cb @(posedge wclk);
    default input #1step output #1ns;
    output write, data_in;
    input  full;
  endclocking

  clocking r_cb @(posedge rclk);
    default input #1step output #1ns;
    output read;
    input  data_out, empty;
  endclocking

  // Modports
  modport DRIVER_MP (
    clocking w_cb,
    clocking r_cb,
    input    wreset, rreset
  );

  modport W_MONITOR_MP (
    clocking w_cb
  );

  modport R_MONITOR_MP (
    clocking r_cb
  );
endinterface
