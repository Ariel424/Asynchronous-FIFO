interface my_interface (input logic wclk, rclk);
    
logic write;
logic wreset;
logic read;
logic rreset;
logic full;
logic empty;
logic [7:0] data_in, data_out;

clocking w_cb @(posedge wclk);
    default input #1ns output #1ns;
    output write;
    output data_in;
    input  full;
endclocking

clocking r_cb @(posedge rclk);
    default input #1ns output #1ns;
    output read;
    input  data_out;
    input  empty;
 endclocking

modport DRIVER (clocking w_cb, clocking r_cb, output wreset output rreset);
modport W_MONITOR (clocking w_cb, input wreset);
modport R_MONITOR (clocking r_cb, input rreset);
    
endinterface 
