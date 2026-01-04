// Asynchronous FIFO Module
module ASYNC_FIFO (
    input WClk, WReset, Write,
    input [7:0] Din,
    output Full,
    input RClk, RReset, Read,
    output reg [7:0] Dout,
    output Empty
);

  reg [7:0] Mem [15:0];
  reg [4:0] WPtr = 0, WGray = 0, RGrayS1 = 0, RGrayS2 = 0;
  reg [4:0] RPtr = 0, RGray = 0, WGrayS1 = 0, WGrayS2 = 0;
  
  // Binary to Gray
  function [4:0] b2g;
    input [4:0] b;
    b2g = b ^ (b >> 1);
  endfunction
  
  // Write domain
  always @(posedge WClk) begin
    if (WReset) begin
      WPtr <= 0; WGray <= 0; RGrayS1 <= 0; RGrayS2 <= 0;
    end
    else begin
      RGrayS1 <= RGray;
      RGrayS2 <= RGrayS1;
      if (Write && !Full) begin
        Mem[WPtr[3:0]] <= Din;
        WPtr <= WPtr + 1;
        WGray <= b2g(WPtr + 1);
      end
    end
  end
  
  // Read domain
  always @(posedge RClk) begin
    if (RReset) begin
      RPtr <= 0; RGray <= 0; WGrayS1 <= 0; WGrayS2 <= 0;
    end
    else begin
      WGrayS1 <= WGray;
      WGrayS2 <= WGrayS1;
      if (Read && !Empty) begin
        Dout <= Mem[RPtr[3:0]];
        RPtr <= RPtr + 1;
        RGray <= b2g(RPtr + 1);
      end
    end
  end
  
  assign Full = (WGray == {~RGrayS2[4:3], RGrayS2[2:0]});
  assign Empty = (RGray == WGrayS2);

endmodule

// Interface
interface ASYNC_FIFO_if;
  logic WClk, RClk, Write, Read, Full, Empty, WReset, RReset;
  logic [7:0] Data_in, Data_out;
endinterface
