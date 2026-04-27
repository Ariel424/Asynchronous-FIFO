// --- Transaction Class ---
class my_transaction;

  rand bit [7:0] data_in;
  rand bit write;
  rand bit read;

  constraint c_data {data {[8'h00 : 8'hFF]}; } 
  constraint c_write_read {
    write dist {1 := 70, 0 := 30};
    read dist {1 := 70, 0 := 30};
  }
  
  function transaction copy();
   my_transaction tr = new();
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
  
  function new(virtual my_interface.DRIVER_MP vif, mailbox #(my_transaction) gen2drv, event drv_done);
    this.vif = vif; 
    this.gen2drv = gen2drv;  
    this.drv_done = drv_done;
  endfunction
  
  task run();
    forever begin
      my_transaction tr;
      gen2drv.get(tr); 
      
      fork 
      drive_write(tr);
      drive_read(tr);
      join
      
      -> drv_done;
    end
  endtask
  
  task drive_write(my_transaction tr);
    @(vif.w_cb);
    vif.w_cb.write <= tr.write;
    vif.w_cb.data_in = tr.data_in;
  endtask
  
  task drive_read(my_transaction tr);
    @(vif.r_cb);
    vif.r_cb.read <= tr.read;
  endtask
endclass

// --- Monitor Class ---
class my_monitor;
  virtual my_interface_W_MONITOR_MP w_vif;
  virtual my_interface.R_MONITO_MP r_vif;
  mailbox #(FIFO_transaction) mbx_write;    
  mailbox #(FIFO_transaction) mbx_read;    
  
  class FIFO_monitor;
    virtual my_interface.W_MONITOR w_vif; 
    virtual my_interface.R_MONITOR r_vif;
    mailbox #(my_transaction) mbx_write; 
    mailbox #(my_transaction) mbx_read;  
    
    function new(virtual my_interface.W_MONITOR w_vif, 
                 virtual my_interface.R_MONITOR r_vif, 
                 mailbox #(my_transaction) mbx_write, 
                 mailbox #(my_transaction) mbx_read);
        this.w_vif = w_vif;
        this.r_vif = r_vif;
        this.mbx_write = mbx_write;
        this.mbx_read = mbx_read;
    endfunction
    
    task run();
        fork
            monitor_write();
            monitor_read();
        join
    endtask
    
    task monitor_write();
        forever begin
            @(w_vif.w_cb);
            if (w_vif.w_cb.write && !w_vif.w_cb.full) begin
                my_transaction tr = new();
                tr.data = w_vif.w_cb.data_in;
                mbx_write.put(tr);
                $display("[%0t] MONITOR_WRITE: Data=0x%0h", $time, tr.data);
            end
        end
    endtask
    
    task monitor_read();
        forever begin
            @(r_vif.r_cb);
            if (r_vif.r_cb.read && !r_vif.r_cb.empty) begin
                // מחכים מחזור נוסף כי המידע יוצא לאחר ה-Clock Edge
                @(r_vif.r_cb); 
                my_transaction tr = new();
                tr.data = r_vif.r_cb.data_out;
                mbx_read.put(tr);
                $display("[%0t] MONITOR_READ: Data=0x%0h", $time, tr.data);
            end
        end
    endtask
endclass

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

    function void report();
        $display("--- Final Report: Matches=%0d, Mismatches=%0d ---", match_count, mismatch_count);
    endfunction
endclass

class FIFO_environment;
    my_generator gen;
    my_driver drv;
    FIFO_monitor mon;
    FIFO_scoreboard scb;
    event drv_done;
    mailbox #(my_transaction) mbx_gen_drv, mbx_mon_scb_w, mbx_mon_scb_r;
    virtual my_interface vif;
    
    function new(virtual my_interface vif, int num_txns = 200);
        this.vif = vif;
        mbx_gen_drv  = new();
        mbx_mon_scb_w = new();
        mbx_mon_scb_r = new();
        
        gen = new(mbx_gen_drv, drv_done, num_txns);
        drv = new(mbx_gen_drv, vif.DRIVER, drv_done);
        mon = new(vif.W_MONITOR, vif.R_MONITOR, mbx_mon_scb_w, mbx_mon_scb_r);
        scb = new(mbx_mon_scb_w, mbx_mon_scb_r);
    endfunction
    
    task run();
        fork
            gen.run();
            drv.run();
            mon.run();
            scb.run();
        join_any
        #1000;
        scb.report();
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
