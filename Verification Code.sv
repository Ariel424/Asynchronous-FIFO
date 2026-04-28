// --- Transaction Class ---
class my_transaction;
  rand bit [7:0] data_in;
  rand bit write;
  rand bit read;
  bit [7:0] data_out;
  bit full, empty;

  constraint c_write_read {
    write dist {1 := 70, 0 := 30};
    read  dist {1 := 70, 0 := 30};
  }
  
  function my_transaction copy();
    my_transaction tr = new();
    tr.data_in = this.data_in;
    tr.write   = this.write;
    tr.read    = this.read;
    tr.data_out = this.data_out;
    tr.full    = this.full;
    tr.empty   = this.empty;
    return tr;
  endfunction
  
  function void display(string tag = "");
    $display("[%0t] %s | W=%0b R=%0b Din=0x%0h Dout=0x%0h F=%0b E=%0b", 
             $time, tag, write, read, data_in, data_out, full, empty);
  endfunction
endclass

// --- Generator Class ---
class my_generator;
  mailbox #(transaction) gen2drv;      
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
      assert(tr.randomize()) else $fatal("Randomization failed");
      gen2drv.put(tr.copy());  
      tr.display("GENERATOR");
      @(drv_done); 
    end
    $display("[%0t] Generator: Completed %0d transactions", $time, num_transactions);
  endtask
endclass

// --- Driver class ---
class my_driver;
  virtual my_interface.DRIVER_MP vif;
  mailbox #(my_transaction) gen2drv;
  event drv_done;

  int timeout_cycles = 100;
  
  function new(virtual my_interface.DRIVER_MP vif, mailbox #(my_transaction) gen2drv, event drv_done);
    this.vif = vif;
    this.gen2drv = gen2drv;
    this.drv_done = drv_done;
  endfunction

  task reset();
  $display("[%0t] Driver: Reset Task Started", $time);
  wait(vif.wreset || vif.rreset);
    vif.w_cb.write   <= 1'b0;
    vif.w_cb.data_in <= 8'b0;
    vif.r_cb.read    <= 1'b0;
  wait(!vif.wreset && !vif.rreset);

  @(vif.w_cb);
   $display("[%0t] Driver: Reset Task Finished - System Ready", $time);
  endtask
    
  task run();
    reset();

    forever begin
      my_transaction tr;
      gen2drv.get(tr);

      fork: transaction_watchdog
        begin
          execute_transaction(tr);
        end
        begin
          repeat(timeout_cycles) @(vif.w_cb);
          $error("[%0t] Watchdog Triggered: Transaction Timeout!", $time);
        end
      join_any 
      disable transaction_watchdog;
      -> drv_done;
    end
  endtask
  
    task execute_transaction(my_transaction tr);
    fork
      // Write Channel
      begin
        @(vif.w_cb);
        if (tr.write && !vif.w_cb.full) begin
          vif.w_cb.write   <= 1'b1;
          vif.w_cb.data_in <= tr.data_in;
          @(vif.w_cb);
        end
        vif.w_cb.write <= 1'b0;
      end
      
      // Read Channel
      begin
        @(vif.r_cb);
        if (tr.read && !vif.r_cb.empty) begin
          vif.r_cb.read <= 1'b1;
          @(vif.r_cb);
        end
        vif.r_cb.read <= 1'b0;
      end
    join
  endtask

endclass

// --- Monitor Class ---
class my_monitor;
  virtual my_interface.W_MONITOR_MP w_vif;
  virtual my_interface.R_MONITOR_MP r_vif;
  mailbox #(my_transaction) mon2scb;

  function new(virtual my_interface.W_MONITOR_MP w_vif, 
              virtual my_interface.R_MONITOR_MP r_vif, 
              mailbox #(my_transaction) mon2scb);
    this.w_vif = w_vif;
    this.r_vif = r_vif;
    this.mon2scb = mon2scb;
  endfunction

  task run();
    fork
      // Monitor Writes
      forever begin
        @(w_vif.w_cb);
        if (w_vif.w_cb.write && !w_vif.w_cb.full) begin
          my_transaction tr = new();
          tr.data_in = w_vif.w_cb.data_in;
          tr.write   = 1;
          tr.full    = w_vif.w_cb.full;
          mon2scb.put(tr);
        end
      end
      // Monitor Reads
      forever begin
        @(r_vif.r_cb);
        if (r_vif.r_cb.read && !r_vif.r_cb.empty) begin
          my_transaction tr = new();
          tr.data_out = r_vif.r_cb.data_out;
          tr.read     = 1;
          tr.empty    = r_vif.r_cb.empty;
          mon2scb.put(tr);
        end
      end
    join
  endtask
endclass

// --- Scoreboard Class ---

class FIFO_scoreboard;
    mailbox #(my_transaction) mbx_write; 
    mailbox #(my_transaction) mbx_read;   
    my_transaction write_queue[$];
    int match_count, mismatch_count;
    
    function new(mailbox #(my_transaction) mbx_write, mailbox #(my_transaction) mbx_read);
        this.mbx_write = mbx_write;
        this.mbx_read = mbx_read;
    endfunction
    
    task run();
        fork
            forever begin
                my_transaction tr;
                mbx_write.get(tr);
                write_queue.push_back(tr);
            end
            forever begin
                my_transaction tr, txn_exp;
                mbx_read.get(tr);
                if (write_queue.size() > 0) begin
                    txn_exp = write_queue.pop_front();
                    if (tr.data == txn_exp.data) match_count++;
                    else mismatch_count++;
                end
            end
        join
    endtask

// --- environment Class ---

class FIFO_environment;
  my_generator gen;
  my_driver    drv;
  my_monitor   mon;
  FIFO_scoreboard scb;
  
  mailbox #(my_transaction) g2d, m2s;
  event drv_done;
  virtual my_interface vif;

  function new(virtual my_interface vif, int num_txns = 200);
    this.vif = vif;
    g2d = new();
    m2s = new();
    
    gen = new(g2d, drv_done, num_txns);
    // חיבור ה-Modports הספציפיים
    drv = new(vif.DRIVER_MP, g2d, drv_done);
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
  
  // --- Coverage Class ---
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
