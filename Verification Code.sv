// ============================================================================
// 1. TRANSACTION CLASS
// ============================================================================
class my_transaction;
  rand bit [7:0] data_in;
  rand bit write, read;
  
  bit [7:0] data_out;
  bit full, empty;

  constraint c_write_read {
    write dist {1 := 70, 0 := 30};
    read  dist {1 := 70, 0 := 30};
  }

  function my_transaction copy();
    my_transaction tr = new();
    tr.data_in  = this.data_in;
    tr.write    = this.write;
    tr.read     = this.read;
    tr.data_out = this.data_out;
    tr.full     = this.full;
    tr.empty    = this.empty;
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
  
  function new(mailbox #(my_transaction) gen2drv, event drv_done, int num_transactions = 100);
    this.gen2drv = gen2drv; 
    this.drv_done = drv_done;
    this.num_transactions = num_transactions;
  endfunction
  
  task run();
    repeat(num_transactions) begin
      my_transaction tr = new(); 
      if (!tr.randomize()) $fatal("Randomization failed");
      gen2drv.put(tr.copy());  
      // tr.display("GENERATOR"); // Disabled to avoid overwhelming the log during stress tests
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
  int timeout_cycles = 5000; // Increased to support extremely slow clock frequencies

  function new(virtual my_interface.DRIVER_MP vif, mailbox #(my_transaction) gen2drv, event drv_done);
    this.vif = vif;
    this.gen2drv = gen2drv;
    this.drv_done = drv_done;
  endfunction

  task reset();
    $display("[%0t] Driver: Waiting for Reset Release...", $time);
    vif.w_cb.write   <= 1'b0;
    vif.r_cb.read    <= 1'b0;
    vif.w_cb.data_in <= 8'b0;
    wait(!vif.wreset && !vif.rreset);
    @(vif.w_cb);
    $display("[%0t] Driver: Reset Released", $time);
  endtask

  task run();
    reset();
    forever begin
      my_transaction tr;
      gen2drv.get(tr);
      
      fork : watchdog_block
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
      // Write Path
      begin
        @(vif.w_cb);
        // For negative/overflow testing: ignore the full flag lock if forced
        if (tr.write) begin
          vif.w_cb.write   <= 1'b1;
          vif.w_cb.data_in <= tr.data_in;
          @(vif.w_cb);
        end
        vif.w_cb.write <= 1'b0;
      end
      // Read Path
      begin
        @(vif.r_cb);
        // For negative/underflow testing: ignore the empty flag lock if forced
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
          tr.data_out = r_vif.r_cb.data_out;
          tr.read = 1;
          tr.empty = r_vif.r_cb.empty;
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
      if (tr.read) begin
        if (queue.size() > 0) begin
          logic [7:0] exp = queue.pop_front();
          if (tr.data_out === exp) matches++;
          else begin 
            $error("Mismatch! Exp: %h, Got: %h", exp, tr.data_out);
            mismatches++;
          end
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
      gen.run(); 
      drv.run();
      mon.run(); 
      scb.run();
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

  // Half-period variables for dynamic frequency scaling (in nanoseconds)
  real write_half_period = 5.0; // Default: 100MHz
  real read_half_period  = 5.0; // Default: 100MHz
  
  bit wclk, rclk;
  
  // Dynamic clock generators driven by period variables
  always #(write_half_period) wclk = ~wclk;
  always #(read_half_period)  rclk = ~rclk;

  // Interface Instance
  my_interface fifo_if(wclk, rclk);

  // DUT Instance
  ASYNC_FIFO dut (
    .WClk(fifo_if.wclk),   .WReset(fifo_if.wreset),
    .Write(fifo_if.write), .Din(fifo_if.data_in),   .Full(fifo_if.full),
    .RClk(fifo_if.rclk),   .RReset(fifo_if.rreset),
    .Read(fifo_if.read),   .Dout(fifo_if.data_out), .Empty(fifo_if.empty)
  );

  // --------------------------------------------------------------------------
  // A. Gray Code Check using SystemVerilog Concurrent Assertions
  // --------------------------------------------------------------------------
  // Assumption: The DUT contains internal pointers named wptr_gray and rptr_gray.
  // These assertions ensure that at most 1 bit changes per clock cycle.
  
  property p_gray_code_write;
    @(posedge fifo_if.wclk) disable iff (fifo_if.wreset)
    $onehot0(dut.wptr_gray ^ $past(dut.wptr_gray));
  endproperty
  assert_write_gray: assert property (p_gray_code_write) else $error("Gray Code Error on Write Pointer!");

  property p_gray_code_read;
    @(posedge fifo_if.rclk) disable iff (fifo_if.rreset)
    $onehot0(dut.rptr_gray ^ $past(dut.rptr_gray));
  endproperty
  assert_read_gray: assert property (p_gray_code_read) else $error("Gray Code Error on Read Pointer!");


  // --------------------------------------------------------------------------
  // Helper Tasks for Test Sequence Management
  // --------------------------------------------------------------------------
  
  // Task for managing Full or Partial Resets
  task do_reset(bit w_rst = 1, bit r_rst = 1, int duration = 40);
    if (w_rst) fifo_if.wreset = 1;
    if (r_rst) fifo_if.rreset = 1;
    #(duration);
    if (w_rst) fifo_if.wreset = 0;
    if (r_rst) fifo_if.rreset = 0;
    $display("[%0t] Reset Task Done (W_Reset=%b, R_Reset=%b)", $time, w_rst, r_rst);
  endtask

  // Task to dynamically change frequencies (Parameters in MHz)
  task set_frequencies(real write_mhz, real read_mhz);
    write_half_period = 1000.0 / (2.0 * write_mhz);
    read_half_period  = 1000.0 / (2.0 * read_mhz);
    $display("[%0t] Frequency changed: Write = %0f MHz, Read = %0f MHz", $time, write_mhz, read_mhz);
    #10; // Short wait for stabilization
  endtask

  // --------------------------------------------------------------------------
  // Main Initial Block - Executes all test scenarios sequentially
  // --------------------------------------------------------------------------
  initial begin
    FIFO_environment env;
    
    // Initializing signals
    fifo_if.write   = 0;
    fifo_if.read    = 0;
    fifo_if.data_in = 0;

    $display("\n=======================================================");
    $display("       STARTING EXTENDED ASYNC FIFO TESTSUITE          ");
    $display("=======================================================\n");

    // ----------------------------------------------------
    // TEST 1: Matched Clocks (100MHz / 100MHz)
    // ----------------------------------------------------
    $display("\n--- [TEST 1] Matched Clocks (100MHz / 100MHz) ---");
    set_frequencies(100.0, 100.0);
    do_reset();
    env = new(fifo_if, 50);
    env.run();
    wait(env.gen.num_transactions == env.scb.matches + env.scb.mismatches);
    #50;

    // ----------------------------------------------------
    // TEST 2: Fast Write, Slow Read (200MHz / 50MHz)
    // ----------------------------------------------------
    $display("\n--- [TEST 2] Fast Write, Slow Read (200MHz / 50MHz) ---");
    set_frequencies(200.0, 50.0);
    do_reset();
    env = new(fifo_if, 50);
    env.run();
    wait(env.gen.num_transactions == env.scb.matches + env.scb.mismatches);
    #50;

    // ----------------------------------------------------
    // TEST 3: Slow Write, Fast Read (50MHz / 200MHz)
    // ----------------------------------------------------
    $display("\n--- [TEST 3] Slow Write, Fast Read (50MHz / 200MHz) ---");
    set_frequencies(50.0, 200.0);
    do_reset();
    env = new(fifo_if, 50);
    env.run();
    wait(env.gen.num_transactions == env.scb.matches + env.scb.mismatches);
    #50;

    // ----------------------------------------------------
    // TEST 4: Basic Flag Sync Latency Check
    // ----------------------------------------------------
    $display("\n--- [TEST 4] Basic Flag Sync Latency Check ---");
    set_frequencies(100.0, 100.0);
    do_reset();
    @(posedge fifo_if.wclk);
    fifo_if.write   <= 1'b1;
    fifo_if.data_in <= 8'hA5;
    @(posedge fifo_if.wclk);
    fifo_if.write   <= 1'b0;
    
    // Counting read clock cycles until the empty flag drops
    fork : empty_timeout
      begin
        int cycles = 0;
        while(fifo_if.empty === 1'b1) begin
          @(posedge fifo_if.rclk);
          cycles++;
        end
        $display("[%0t] Success: Empty flag dropped after %0d Read cycles.", $time, cycles);
      end
      begin
        #200;
        $error("Timeout: Empty flag did not drop!");
      end
    endfork
    disable empty_timeout;

    // ----------------------------------------------------
    // TEST 5: Corner Case - Ultra-Fast Write (500MHz / 1MHz)
    // ----------------------------------------------------
    $display("\n--- [TEST 5] Corner Case: Ultra-Fast Write (500MHz / 1MHz) ---");
    set_frequencies(500.0, 1.0);
    do_reset();
    env = new(fifo_if, 30);
    env.run();
    wait(env.gen.num_transactions == env.scb.matches + env.scb.mismatches);
    #2000; // Allow enough time for the ultra-slow read clock to complete processing

    // ----------------------------------------------------
    // TEST 6: Corner Case - Ultra-Fast Read (1MHz / 500MHz)
    // ----------------------------------------------------
    $display("\n--- [TEST 6] Corner Case: Ultra-Fast Read (1MHz / 500MHz) ---");
    set_frequencies(1.0, 500.0);
    do_reset();
    env = new(fifo_if, 20);
    env.run();
    wait(env.gen.num_transactions == env.scb.matches + env.scb.mismatches);
    #2000;

    // ----------------------------------------------------
    // TEST 7: Corner Case - 180 Degrees Out of Phase
    // ----------------------------------------------------
    $display("\n--- [TEST 7] Corner Case: 180 Degrees Out of Phase ---");
    set_frequencies(100.0, 100.0);
    // Shifts read clock phase by 180 degrees (half period = 5ns for 100MHz)
    wclk = 0; rclk = 0;
    write_half_period = 5.0; read_half_period = 5.0;
    #5; // Offset the starting edge of the read clock
    fork
      forever #5 wclk = ~wclk;
      forever #5 rclk = ~rclk;
    join_none
    do_reset();
    env = new(fifo_if, 40);
    env.run();
    wait(env.gen.num_transactions == env.scb.matches + env.scb.mismatches);

    // ----------------------------------------------------
    // TEST 8: Corner Case - Partial Domain Reset
    // ----------------------------------------------------
    $display("\n--- [TEST 8] Corner Case: Partial Domain Reset (Write Domain Only) ---");
    set_frequencies(100.0, 100.0);
    do_reset();
    env = new(fifo_if, 40);
    env.run();
    #100;
    $display("[%0t] Injecting Write-Domain Reset while running...", $time);
    do_reset(.w_rst(1), .r_rst(0), .duration(50)); // Only Write Reset triggered
    #100;

    // ----------------------------------------------------
    // TEST 9: Corner Case - Full to Empty Toggle
    // ----------------------------------------------------
    $display("\n--- [TEST 9] Corner Case: Full to Empty Toggle ---");
    set_frequencies(200.0, 200.0);
    do_reset();
    // Aggressive fill sequence without reading
    $display("Filling FIFO to Full...");
    while(!fifo_if.full) begin
      @(posedge fifo_if.wclk);
      fifo_if.write   <= 1'b1;
      fifo_if.data_in <= $urandom();
    end
    fifo_if.write <= 1'b0;
    
    // Aggressive read sequence without writing
    $display("Emptying FIFO to Empty...");
    while(!fifo_if.empty) begin
      @(posedge fifo_if.rclk);
      fifo_if.read <= 1'b1;
    end
    fifo_if.read <= 1'b0;
    #50;

    // ----------------------------------------------------
    // TEST 10: Stress - Status Jitter (Burst Write, Jitter Read)
    // ----------------------------------------------------
    $display("\n--- [TEST 10] Stress: Status Jitter (Burst Write, Jitter Read) ---");
    set_frequencies(200.0, 150.0);
    do_reset();
    fork
      // Continuous burst write of 500 words
      repeat(500) begin
        @(posedge fifo_if.wclk);
        if(!fifo_if.full) begin
          fifo_if.write   <= 1'b1;
          fifo_if.data_in <= $urandom();
        end
      end
      // Reading with random jitter insertion
      repeat(500) begin
        @(posedge fifo_if.rclk);
        if(!fifo_if.empty) fifo_if.read <= 1'b1;
        else fifo_if.read <= 1'b0;
        #( $urandom_range(1, 15) ); // Dynamic time-interval jitter simulation
      end
    join
    fifo_if.write <= 1'b0; fifo_if.read <= 1'b0;
    #100;

    // ----------------------------------------------------
    // TEST 11: Stress - Dynamic Frequency Scaling (DFS)
    // ----------------------------------------------------
    $display("\n--- [TEST 11] Stress: Dynamic Frequency Scaling ---");
    set_frequencies(100.0, 100.0);
    do_reset();
    env = new(fifo_if, 100);
    fork
      env.run();
      begin
        #200;
        $display("[%0t] Dynamic Scale: Boosting Write Clock to 250MHz!", $time);
        set_frequencies(250.0, 100.0);
        #300;
        $display("[%0t] Dynamic Scale: Dropping Read Clock to 30MHz!", $time);
        set_frequencies(250.0, 30.0);
      end
    join_any
    #500;

    // ----------------------------------------------------
    // TEST 12: Negative - Overflow/Underflow Continuous Bombing
    // ----------------------------------------------------
    $display("\n--- [TEST 12] Negative: Overflow/Underflow Continuous Bombing ---");
    set_frequencies(200.0, 50.0); // Fast write domain, slow read domain
    do_reset();
    
    $display("Bombarding Write on FULL FIFO...");
    repeat(100) begin
      @(posedge fifo_if.wclk);
      fifo_if.write   <= 1'b1; // Keeping write active even if full
      fifo_if.data_in <= 8'hFF;
    end
    fifo_if.write <= 1'b0;

    set_frequencies(50.0, 200.0); // Switching dynamics to fast read domain
    $display("Bombarding Read on EMPTY FIFO...");
    repeat(100) begin
      @(posedge fifo_if.rclk);
      fifo_if.read <= 1'b1;  // Keeping read active even if empty
    end
    fifo_if.read <= 1'b0;

    // ----------------------------------------------------
    // TEST 13: Stress - Clashing Asynchronous Resets
    // ----------------------------------------------------
    $display("\n--- [TEST 13] Stress: Clashing Asynchronous Resets ---");
    set_frequencies(150.0, 150.0);
    fork
      // Asserting reset signals at heavily unaligned times
      begin #10; fifo_if.wreset = 1; #23; fifo_if.wreset = 0; end
      begin #18; fifo_if.rreset = 1; #35; fifo_if.rreset = 0; end
      begin
        repeat(50) begin
          @(posedge fifo_if.wclk);
          fifo_if.write <= 1'b1;
          fifo_if.data_in <= $urandom();
        end
      end
    join
    fifo_if.write <= 1'b0;
    #100;

    // ====================================================
    // SIMULATION WRAP-UP
    // ====================================================
    $display("\n=======================================================");
    $display("     ALL ASYNC FIFO TEST CASES COMPLETED SUCCESSFULLY  ");
    $display("=======================================================");
    $finish;
  end

  // Waveform Dumper Config
  initial begin
    $dumpfile("fifo_extended.vcd");
    $dumpvars(0, tb_async_fifo);
  end

endmodule
