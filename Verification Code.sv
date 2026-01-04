// Transaction Class
class FIFO_transaction;
  // Data members
  rand bit [7:0] data;
  rand bit write;
  rand bit read;
  
  // Transaction handle - each instance has its own
  FIFO_transaction tr;
  
  constraint c_write_read {
    write dist {1 := 70, 0 := 30};
    read dist {1 := 70, 0 := 30};
  }
  
  // Copy function using handle
  function FIFO_transaction copy();
    tr = new();
    tr.data = this.data;
    tr.write = this.write;
    tr.read = this.read;
    return tr;
  endfunction
  
  function void display(string tag = "");
    $display("[%0t] %s Write=%0b Read=%0b Data=0x%0h", 
             $time, tag, write, read, data);
  endfunction
endclass

// Generator Class (NEW - produces transactions)
class FIFO_generator;
  mailbox #(FIFO_transaction) mbx;  // Handle to mailbox
  FIFO_transaction tr;              // Transaction handle (reused)
  int num_transactions;
  
  function new(mailbox #(FIFO_transaction) mbx, int num_txns = 100);
    this.mbx = mbx;  // Store mailbox handle
    this.num_transactions = num_txns;
    tr = new();      // Create transaction handle once
  endfunction
  
  task run();
    repeat(num_transactions) begin
      assert(tr.randomize()) else $error("Randomization failed");
      mbx.put(tr);
      tr.display("GENERATOR");
    end
    $display("[%0t] Generator: Completed %0d transactions", $time, num_transactions);
  endtask
endclass

// Driver Class
class FIFO_driver;
  virtual ASYNC_FIFO_if vif;           // Handle to virtual interface
  mailbox #(FIFO_transaction) mbx;     // Handle to mailbox
  FIFO_transaction tr;                 // Transaction handle (reused)
  
  function new(mailbox #(FIFO_transaction) mbx, virtual ASYNC_FIFO_if vif);
    this.mbx = mbx;  // Store mailbox handle
    this.vif = vif;  // Store interface handle
  endfunction
  
  task run();
    forever begin
      mbx.get(tr);  // Get transaction from mailbox via handle
      drive_write(tr);
      drive_read(tr);
      tr.display("DRIVER");
    end
  endtask
  
  task drive_write(FIFO_transaction tr);
    @(posedge vif.WClk);
    vif.Write = tr.write;
    vif.Data_in = tr.data;
  endtask
  
  task drive_read(FIFO_transaction tr);
    @(posedge vif.RClk);
    vif.Read = tr.read;
  endtask
endclass

// Monitor Class
class FIFO_monitor;
  virtual ASYNC_FIFO_if vif;                // Handle to virtual interface
  mailbox #(FIFO_transaction) mbx_write;    // Handle to write mailbox
  mailbox #(FIFO_transaction) mbx_read;     // Handle to read mailbox
  FIFO_transaction tr;                      // Transaction handle (reused)
  
  function new(virtual ASYNC_FIFO_if vif);
    this.vif = vif;  // Store interface handle
    mbx_write = new();  // Create and store write mailbox handle
    mbx_read = new();   // Create and store read mailbox handle
  endfunction
  
  task run();
    fork
      monitor_write();
      monitor_read();
    join
  endtask
  
  task monitor_write();
    forever begin
      @(posedge vif.WClk);
      if (vif.Write && !vif.Full) begin
        tr = new();
        tr.data = vif.Data_in;
        tr.write = 1;
        mbx_write.put(tr);  // Send via mailbox handle
        $display("[%0t] MONITOR_WRITE: Data=0x%0h", $time, tr.data);
      end
    end
  endtask
  
  task monitor_read();
    forever begin
      @(posedge vif.RClk);
      if (vif.Read && !vif.Empty) begin
        @(posedge vif.RClk); // Wait for output
        tr = new();
        tr.data = vif.Data_out;
        tr.read = 1;
        mbx_read.put(tr);  // Send via mailbox handle
        $display("[%0t] MONITOR_READ: Data=0x%0h", $time, tr.data);
      end
    end
  endtask
endclass

// Scoreboard Class
class FIFO_scoreboard;
  mailbox #(FIFO_transaction) mbx_write;  // Handle to write mailbox
  mailbox #(FIFO_transaction) mbx_read;   // Handle to read mailbox
  FIFO_transaction tr;                    // Transaction handle (reused)
  FIFO_transaction write_queue[$];
  int match_count = 0;
  int mismatch_count = 0;
  
  function new(mailbox #(FIFO_transaction) mbx_w, mailbox #(FIFO_transaction) mbx_r);
    this.mbx_write = mbx_w;  // Store write mailbox handle
    this.mbx_read = mbx_r;   // Store read mailbox handle
  endfunction
  
  task run();
    fork
      collect_write();
      check_read();
    join
  endtask
  
  task collect_write();
    forever begin
      mbx_write.get(tr);  // Receive via mailbox handle
      write_queue.push_back(tr);
    end
  endtask
  
  task check_read();
    FIFO_transaction txn_expected;
    forever begin
      mbx_read.get(tr);  // Receive via mailbox handle
      if (write_queue.size() > 0) begin
        txn_expected = write_queue.pop_front();
        if (tr.data == txn_expected.data) begin
          match_count++;
          $display("[%0t] SCOREBOARD MATCH: Expected=0x%0h Got=0x%0h", 
                   $time, txn_expected.data, tr.data);
        end else begin
          mismatch_count++;
          $display("[%0t] SCOREBOARD MISMATCH: Expected=0x%0h Got=0x%0h", 
                   $time, txn_expected.data, tr.data);
        end
      end else begin
        $display("[%0t] SCOREBOARD ERROR: Read from empty FIFO", $time);
        mismatch_count++;
      end
    end
  endtask
  
  function void report();
    $display("\n===== SCOREBOARD REPORT =====");
    $display("Matches: %0d", match_count);
    $display("Mismatches: %0d", mismatch_count);
    $display("Remaining in queue: %0d", write_queue.size());
    if (mismatch_count == 0)
      $display("TEST PASSED");
    else
      $display("TEST FAILED");
    $display("=============================\n");
  endfunction
endclass

// Environment Class
class FIFO_environment;
  FIFO_generator gen;                       // Handle to generator
  FIFO_driver drv;                          // Handle to driver
  FIFO_monitor mon;                         // Handle to monitor
  FIFO_scoreboard scb;                      // Handle to scoreboard
  mailbox #(FIFO_transaction) mbx_gen_drv; // Handle to gen->drv mailbox
  virtual ASYNC_FIFO_if vif;                // Handle to virtual interface
  
  function new(virtual ASYNC_FIFO_if vif, int num_txns = 200);
    this.vif = vif;  // Store interface handle
    
    // Create mailbox handle for generator->driver communication
    mbx_gen_drv = new();
    
    // Create component handles and pass necessary handles to them
    gen = new(mbx_gen_drv, num_txns);        // Pass mailbox handle to generator
    drv = new(mbx_gen_drv, vif);             // Pass mailbox and interface handles to driver
    mon = new(vif);                          // Pass interface handle to monitor
    scb = new(mon.mbx_write, mon.mbx_read);  // Pass monitor's mailbox handles to scoreboard
    
    $display("Environment created with handles:");
    $display("  - Generator handle: %p", gen);
    $display("  - Driver handle: %p", drv);
    $display("  - Monitor handle: %p", mon);
    $display("  - Scoreboard handle: %p", scb);
  endfunction
  
  task run();
    fork
      gen.run();  // Start generator via its handle
      drv.run();  // Start driver via its handle
      mon.run();  // Start monitor via its handle
      scb.run();  // Start scoreboard via its handle
    join_none
    
    // Wait for generator to complete
    wait(gen.num_transactions == 0 || $time > 50000);
    #10000;  // Additional time for pipeline to drain
  endtask
  
  function void report();
    scb.report();  // Call scoreboard report via its handle
  endfunction
endclass

// Testbench Module
module tb_async_fifo;
  // Clock generation
  bit WClk = 0, RClk = 0;
  always #5 WClk = ~WClk;  // 100MHz
  always #7 RClk = ~RClk;  // ~71MHz (different frequency)
  
  // Interface instantiation
  ASYNC_FIFO_if fifo_if();
  
  // DUT instantiation
  ASYNC_FIFO dut (
    .WClk(fifo_if.WClk),
    .WReset(fifo_if.WReset),
    .Write(fifo_if.Write),
    .Din(fifo_if.Data_in),
    .Full(fifo_if.Full),
    .RClk(fifo_if.RClk),
    .RReset(fifo_if.RReset),
    .Read(fifo_if.Read),
    .Dout(fifo_if.Data_out),
    .Empty(fifo_if.Empty)
  );
  
  // Connect clocks
  assign fifo_if.WClk = WClk;
  assign fifo_if.RClk = RClk;
  
  // Coverage
  covergroup fifo_cg @(posedge WClk);
    cp_write: coverpoint fifo_if.Write {
      bins write_0 = {0};
      bins write_1 = {1};
    }
    cp_full: coverpoint fifo_if.Full {
      bins full_0 = {0};
      bins full_1 = {1};
    }
    cp_data: coverpoint fifo_if.Data_in {
      bins low = {[0:63]};
      bins mid = {[64:191]};
      bins high = {[192:255]};
    }
    cross_write_full: cross cp_write, cp_full;
  endgroup
  
  covergroup fifo_read_cg @(posedge RClk);
    cp_read: coverpoint fifo_if.Read {
      bins read_0 = {0};
      bins read_1 = {1};
    }
    cp_empty: coverpoint fifo_if.Empty {
      bins empty_0 = {0};
      bins empty_1 = {1};
    }
    cross_read_empty: cross cp_read, cp_empty;
  endgroup
  
  // Assertions
  property p_no_write_when_full;
    @(posedge WClk) (fifo_if.Full && fifo_if.Write) |=> $stable(fifo_if.Full);
  endproperty
  
  property p_no_read_when_empty;
    @(posedge RClk) (fifo_if.Empty && fifo_if.Read) |=> $stable(fifo_if.Empty);
  endproperty
  
  assert_no_write_full: assert property(p_no_write_when_full)
    else $error("Write occurred when FIFO was full");
  
  assert_no_read_empty: assert property(p_no_read_when_empty)
    else $error("Read occurred when FIFO was empty");
  
  // Test execution
  initial begin
    FIFO_environment env;  // Handle to environment
    fifo_cg fcg = new();
    fifo_read_cg frcg = new();
    
    // Initialize
    fifo_if.Write = 0;
    fifo_if.Read = 0;
    fifo_if.Data_in = 0;
    fifo_if.WReset = 1;
    fifo_if.RReset = 1;
    
    repeat(10) @(posedge WClk);
    fifo_if.WReset = 0;
    fifo_if.RReset = 0;
    repeat(10) @(posedge WClk);
    
    // Create environment handle and pass interface handle + number of transactions
    env = new(fifo_if, 200);
    
    $display("\n========================================");
    $display("Starting FIFO Verification with Handles");
    $display("========================================\n");
    
    // Run test via environment handle
    env.run();
    
    // Report results via environment handle
    repeat(100) @(posedge WClk);
    env.report();
    
    $display("\nCoverage Results:");
    $display("Write Coverage: %.2f%%", fcg.get_coverage());
    $display("Read Coverage: %.2f%%", frcg.get_coverage());
    
    $finish;
  end
  
  // Waveform dump
  initial begin
    $dumpfile("fifo.vcd");
    $dumpvars(0, tb_async_fifo);
  end
endmodule
