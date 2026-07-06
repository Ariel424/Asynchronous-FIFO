// ============================================================================
// PROJECT: ASYNCHRONOUS FIFO VERIFICATION BENCHMARK
// ENGINEER: ARIEL TOPAZ
// ARCHITECTURE: CLEAN TARGETED CDC ENVIRONMENT (DVFS, JITTER & RESET CLASH)
// ============================================================================

// ============================================================================
// 1. TRANSACTION CLASS
// ============================================================================
class my_transaction;
  rand bit [7:0] data_in;
  rand bit write, read;
  bit [7:0] data_out;
  bit full, empty;

  int write_weight = 50;
  int read_weight = 50;

  constraint c_write_read {
    write dist {1 := write_weight, 0 := (100 - write_weight)};
    read dist {1 := read_weight, 0 := (100 - read_weight)};
  }

  function my_transaction copy();
    my_transaction tr = new();
    tr.data_in  = this.data_in;
    tr.write = this.write;
    tr.read = this.read;
    tr.data_out = this.data_out;
    tr.full = this.full; 
    tr.empty = this.empty;
    return tr;
  endfunction

  function void display(string tag = "");
    $display("[%0t] %s | W=%0b R=%0b Din=0x%0h Dout=0x%0h F=%0b E=%0b", 
             $time, tag, write, read, data_in, data_out, full, empty);
  endfunction
endclass

// ============================================================================
// 2. GENERATOR CLASS
// ============================================================================
class my_generator;
  mailbox #(my_transaction) gen2drv;      
  int num_transactions;  
  event drv_done;
  
  function new(mailbox #(my_transaction) gen2drv, event drv_done);
    this.gen2drv = gen2drv; 
    this.drv_done = drv_done;
  endfunction
  
  task run();
    repeat(num_transactions) begin
      my_transaction tr = new(); 
      if (!tr.randomize()) $fatal("Randomization failed");
      gen2drv.put(tr.copy());  
      @(drv_done); 
    end
    $display("[%0t] Generator: Completed %0d transactions", $time, num_transactions);
  endtask
endclass

// ============================================================================
// 3. DRIVER CLASS
// ============================================================================
class my_driver;
  virtual my_interface.DRIVER_MP vif;
  mailbox #(my_transaction) gen2drv;
  event drv_done;
  int timeout_cycles = 5000; 

  function new(virtual my_interface.DRIVER_MP vif, mailbox #(my_transaction) gen2drv, event drv_done);
    this.vif = vif; 
    this.gen2drv = gen2drv; 
    this.drv_done = drv_done;
  endfunction

  task reset();
    vif.w_cb.write <= 0;
    vif.r_cb.read <= 0;
    vif.w_cb.data_in <= 0;
    wait(!vif.wreset && !vif.rreset);
    repeat (5) begin @(vif.w_cb);
  endtask

  task run();
    reset();
    forever begin
      my_transaction tr;
      gen2drv.get(tr);
      
      fork: watchdog_block
        execute_transaction(tr);
        begin
          repeat(timeout_cycles) @(vif.w_cb);
          $error("Driver: Timeout reached!");
        end
      endfork
      disable watchdog_block;
      -> drv_done;
    end
  endtask

  task execute_transaction(my_transaction tr);
    fork
      begin // Write Path
        @(vif.w_cb);
        if (tr.write) begin
          vif.w_cb.write   <= 1'b1;
          vif.w_cb.data_in <= tr.data_in;
          @(vif.w_cb);
        end
        vif.w_cb.write <= 1'b0;
      end
      begin // Read Path
        @(vif.r_cb);
        if (tr.read) begin
          vif.r_cb.read <= 1'b1;
          @(vif.r_cb);
        end
        vif.r_cb.read <= 1'b0;
      end
    join
  endtask
endclass

// ============================================================================
// 4. MONITOR CLASS
// ============================================================================
class my_monitor;
  virtual my_interface.W_MONITOR_MP w_vif;
  virtual my_interface.R_MONITOR_MP r_vif;
  mailbox #(my_transaction) mon2scb;

  function new(virtual my_interface.W_MONITOR_MP w_vif, virtual my_interface.R_MONITOR_MP r_vif, mailbox #(my_transaction) mon2scb);
    this.w_vif = w_vif; 
    this.r_vif = r_vif;
    this.mon2scb = mon2scb;
  endfunction

  task run();
    fork
      forever begin // Write Monitor
        @(w_vif.w_cb);
        if (w_vif.w_cb.write && !w_vif.w_cb.full) begin
          my_transaction tr = new();
          tr.data_in = w_vif.w_cb.data_in;
          tr.write = 1;
          tr.full = w_vif.w_cb.full;
          mon2scb.put(tr);
        end
      end
      forever begin // Read Monitor
        @(r_vif.r_cb);
        if (r_vif.r_cb.read && !r_vif.r_cb.empty) begin
          my_transaction tr = new();
          tr.data_out = r_vif.r_cb.data_out; tr.read = 1; tr.empty = r_vif.r_cb.empty;
          mon2scb.put(tr);
        end
      end
    join
  endtask
endclass

// ============================================================================
// 5. SCOREBOARD CLASS
// ============================================================================
class FIFO_scoreboard;
  mailbox #(my_transaction) mon2scb;
  logic [7:0] queue[$];
  int matches, mismatches;

  function new(mailbox #(my_transaction) mon2scb);
    this.mon2scb = mon2scb;
  endfunction

  task run();
    forever begin
      my_transaction tr;
      mon2scb.get(tr);
      if (tr.write) queue.push_back(tr.data_in);
      if (tr.read && queue.size() > 0) begin
        logic [7:0] exp = queue.pop_front();
        if (tr.data_out === exp) matches++;
        else begin 
          $error("Mismatch! Exp: %h, Got: %h", exp, tr.data_out);
          mismatches++;
        end
      end
    end
  endtask

  function void report();
    $display("\n=============================");
    $display("         FINAL REPORT        ");
    $display("=============================");
    $display("Matches:    %0d", matches);
    $display("Mismatches: %0d", mismatches);
    $display("=============================\n");
  endfunction
endclass

// ============================================================================
// 6. ENVIRONMENT CLASS
// ============================================================================
class FIFO_environment;
  my_generator gen;
  my_driver drv;
  my_monitor mon;
  FIFO_scoreboard scb;
  mailbox #(my_transaction) g2d, m2s;
  event d_done;
  virtual my_interface vif;

  function new(virtual my_interface vif, int num);
    this.vif = vif;
    g2d = new(); m2s = new();
    gen = new(g2d, d_done, num);
    drv = new(vif.DRIVER_MP, g2d, d_done);
    mon = new(vif.W_MONITOR_MP, vif.R_MONITOR_MP, m2s);
    scb = new(m2s);
  endfunction

  task run();
    fork
      gen.run(); drv.run(); mon.run(); scb.run();
    join_any
  endtask
  
  function void report();
    scb.report();
  endfunction
endclass


// ============================================================================
// 7. TESTBENCH TOP MODULE
// ============================================================================
module tb_async_fifo;

  real write_base_period = 5.0, read_base_period = 5.0; 
  bit  w_jitter_en = 0, r_jitter_en = 0;
  bit  wclk, rclk;
  
  // Dynamic Clock Generators with integrated 15% Jitter Injection Engine
  always begin
    real j = w_jitter_en ? (real'($urandom())/4294967295.0 - 0.5) * (write_base_period * 0.3) : 0;
    #(write_base_period + j) wclk = ~wclk;
  end

  always begin
    real j = r_jitter_en ? (real'($urandom())/4294967295.0 - 0.5) * (read_base_period * 0.3) : 0;
    #(read_base_period + j) rclk = ~rclk;
  end

  // Interface & DUT Instantiation
  my_interface fifo_if(wclk, rclk);

  ASYNC_FIFO dut (
    .WClk(fifo_if.wclk),   .WReset(fifo_if.wreset),
    .Write(fifo_if.write), .Din(fifo_if.data_in),   .Full(fifo_if.full),
    .RClk(fifo_if.rclk),   .RReset(fifo_if.rreset),
    .Read(fifo_if.read),   .Dout(fifo_if.data_out), .Empty(fifo_if.empty)
  );

  // Concurrent Gray Code SVA Assertions
  assert_write_gray: assert property (@(posedge fifo_if.wclk) disable iff (fifo_if.wreset) $onehot0(dut.wptr_gray ^ $past(dut.wptr_gray))) else $error("Gray Code Error on Write Pointer!");
  assert_read_gray:  assert property (@(posedge fifo_if.rclk) disable iff (fifo_if.rreset) $onehot0(dut.rptr_gray ^ $past(dut.rptr_gray))) else $error("Gray Code Error on Read Pointer!");

  // Configuration Helper Tasks
  task do_reset(int duration = 40);
    fifo_if.wreset = 1; fifo_if.rreset = 1;
    #(duration);
    fifo_if.wreset = 0; fifo_if.rreset = 0;
  endtask

  task set_frequencies(real write_mhz, real read_mhz);
    write_base_period = 1000.0 / (2.0 * write_mhz);
    read_base_period  = 1000.0 / (2.0 * read_mhz);
    // Optional Tracking Flags for Interface Coverage Matrix
    fifo_if.w_freq_mode = (write_mhz <= 20.0) ? 2'b00 : (write_mhz >= 400.0) ? 2'b10 : 2'b01;
    fifo_if.r_freq_mode = (read_mhz <= 20.0)  ? 2'b00 : (read_mhz >= 400.0)  ? 2'b10 : 2'b01;
    $display("[%0t] [DVFS] Frequencies set to: Write = %0f MHz, Read = %0f MHz", $time, write_mhz, read_mhz);
  endtask

  // --------------------------------------------------------------------------
  // MAIN INITIAL BLOCK - THREE SELECTED HIGH-VALUE CDC VECTORS
  // --------------------------------------------------------------------------
  initial begin
    FIFO_environment env;
    {fifo_if.write, fifo_if.read, fifo_if.data_in} = 0;

    $display("\n=======================================================");
    $display("   STARTING ARIEL TOPAZ PRODUCTION TESTSUITE (3 CORE CDC)");
    $display("=======================================================\n");

    // ----------------------------------------------------
    // VECTOR 1: ADVANCED DVFS MIXED MATRIX RUN
    // ----------------------------------------------------
    $display("\n--- [VECTOR 1] DVFS Matrix Functional Stress ---");
    
    $display("Scenario A: Fast Write (500MHz) vs. Slow Read (10MHz)");
    set_frequencies(500.0, 10.0); do_reset();
    env = new(fifo_if, 40); fork env.run(); join_any #200; 

    $display("Scenario B: Slow Write (10MHz) vs. Fast Read (500MHz)");
    set_frequencies(10.0, 500.0); do_reset();
    env = new(fifo_if, 40); fork env.run(); join_any #500;

    // ----------------------------------------------------
    // VECTOR 2: AGGRESSIVE PHYSICAL CDC JITTER BOMBING
    // ----------------------------------------------------
    $display("\n--- [VECTOR 2] CDC Physical Stress: Dynamic Clock Jitter Active ---");
    set_frequencies(133.33, 87.5); do_reset(); // Shifting phases naturally
    
    {w_jitter_en, r_jitter_en} = 2'b11; // Enable jitter engines
    env = new(fifo_if, 120); 
    fork env.run(); join_any 
    #500;
    {w_jitter_en, r_jitter_en} = 2'b00; // Disable jitter for stability shutdown

    // ----------------------------------------------------
    // VECTOR 3: STRESS - ASYNCHRONOUS RESET CLASHING
    // ----------------------------------------------------
    $display("\n--- [VECTOR 3] Stress: Clashing Asynchronous Resets ---");
    set_frequencies(150.0, 150.0); do_reset();
    
    fork
      begin #12; fifo_if.wreset = 1; #25; fifo_if.wreset = 0; end // Random write reset pulse
      begin #20; fifo_if.rreset = 1; #38; fifo_if.rreset = 0; end // Overlapping read reset pulse
      begin
        repeat(60) begin
          @(posedge fifo_if.wclk);
          fifo_if.write   <= (!fifo_if.full && !fifo_if.wreset);
          fifo_if.data_in <= $urandom();
        end
        fifo_if.write <= 0;
      end
    join
    #200;

    // Sim Complete
    env.report();
    $finish;
  end

  // Waveform Dumper Config
  initial begin
    $dumpfile("fifo_targeted_cdc.vcd");
    $dumpvars(0, tb_async_fifo);
  end

endmodule
