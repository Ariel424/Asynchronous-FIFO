// asynchronous fifo module
module async_fifo (
    input wclk, wreset, write,
    input [7:0] din,
    output full,
    input rclk, rreset, read,
    output reg [7:0] dout,
    output empty
);

  logic [7:0] mem [15:0];
  logic [4:0] wptr = 0, wgray = 0, rgrays1 = 0, rgrays2 = 0;
  logic [4:0] rptr = 0, rgray = 0, wgrays1 = 0, wgrays2 = 0;
  
  // binary to gray
  function [4:0] b2g;
    input [4:0] b;
    b2g = b ^ (b >> 1);
  endfunction
  
  // write domain
  always_ff @(posedge wclk) begin
    if (wreset) begin
      wptr <= 0; wgray <= 0; rgrays1 <= 0; rgrays2 <= 0;
    end
    else begin
      rgrays1 <= rgray;
      rgrays2 <= rgrays1;
      if (write && !full) begin
        mem[wptr[3:0]] <= din;
        wptr <= wptr + 1;
        wgray <= b2g(wptr + 1);
      end
    end
  end
  
  // read domain
  always_ff @(posedge rclk) begin
    if (rreset) begin
      rptr <= 0; rgray <= 0; wgrays1 <= 0; wgrays2 <= 0;
    end
    else begin
      wgrays1 <= wgray;
      wgrays2 <= wgrays1;
      if (read && !empty) begin
        dout <= mem[rptr[3:0]];
        rptr <= rptr + 1;
        rgray <= b2g(rptr + 1);
      end
    end
  end
  
  assign full = (wgray == {~rgrays2[4:3], rgrays2[2:0]});
  assign empty = (rgray == wgrays1);

endmodule
