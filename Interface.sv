interface my_interface (input logic wclk, input logic rclk);

    logic wreset, rreset;
    logic write, read;
    logic full, empty;
    logic [7:0] data_in, data_out;
    
    // --- DVFS Tracking Signals ---
    logic [1:0] w_freq_mode; // 00: Slow (10MHz), 01: Nominal (100MHz), 10: Fast (500MHz)
    logic [1:0] r_freq_mode;
    bit assertions_en = 1;

    // --- Clocking Blocks (Slightly reduced Skew for Ultra-High Frequencies support) ---
    clocking w_cb @(posedge wclk);
        default input #100ps output #100ps; 
        output write;
        output data_in;
        input  full;
    endclocking

    clocking r_cb @(posedge rclk);
        default input #100ps output #100ps;
        output read;
        input  data_out;
        input  empty;
    endclocking

    modport DRIVER_MP (
        clocking w_cb, 
        clocking r_cb, 
        output wreset, 
        output rreset,
        input wclk,
        input rclk
    );

    modport W_MONITOR_MP (clocking w_cb, input wreset);
    modport R_MONITOR_MP (clocking r_cb, input rreset);

    // ========================================================================
    // ARIEL TOPAZ - CDC & PROTOCOL ASSERTIONS (SVA)
    // ========================================================================
    
    property p_no_write_when_full;
        @(posedge wclk) disable iff (wreset || !assertions_en)
        (write && full) |=> $stable(full);
    endproperty
    assert_no_write_full: assert property(p_no_write_when_full) else $error("[SVA ERROR] Write occurred when FIFO was full");
    
    property p_no_read_when_empty;
        @(posedge rclk) disable iff (rreset || !assertions_en)
        (read && empty) |=> $stable(empty);
    endproperty
    assert_no_read_empty: assert property(p_no_read_when_empty) else $error("[SVA ERROR] Read occurred when FIFO was empty");
    
endinterface
