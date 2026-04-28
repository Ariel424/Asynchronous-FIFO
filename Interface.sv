interface my_interface (input logic wclk, rclk);
    
logic wreset;
logic rreset;
logic write;
logic read;
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

modport DRIVER_MP (clocking w_cb, clocking r_cb, output wreset output rreset);
modport W_MONITOR_MP (clocking w_cb, input wreset);
modport R_MONITOR_MP (clocking r_cb, input rreset);
    
endinterface 
