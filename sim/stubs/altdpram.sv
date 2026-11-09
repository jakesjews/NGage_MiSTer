module altdpram #(
parameter width=32,widthad=6,numwords=64,
parameter intended_device_family="Cyclone V",ram_block_type="MLAB",
parameter indata_reg="INCLOCK",wraddress_reg="INCLOCK",wrcontrol_reg="INCLOCK",
parameter rdaddress_reg="UNREGISTERED",rdcontrol_reg="UNREGISTERED",outdata_reg="UNREGISTERED",
parameter indata_aclr="OFF",wraddress_aclr="OFF",wrcontrol_aclr="OFF",
parameter rdaddress_aclr="OFF",rdcontrol_aclr="OFF",outdata_aclr="OFF",outdata_sclr="OFF",
parameter read_during_write_mode_mixed_ports="DONT_CARE")(
input inclock,inclocken,outclock,outclocken,aclr,sclr,wren,rden,byteena,wraddressstall,rdaddressstall,
input [widthad-1:0] wraddress,rdaddress,input [width-1:0] data,output [width-1:0] q);
logic [width-1:0] mem[0:numwords-1];
always @(posedge inclock) if(inclocken&&wren&&byteena)mem[wraddress]<=data;
// Writes and asynchronous reads match the configured altdpram mode. The
// caller bypasses active and just-committed writes; poison active collisions.
assign q=wren&&wraddress==rdaddress?'x:mem[rdaddress];
initial begin
    if(indata_reg!="INCLOCK"||wraddress_reg!="INCLOCK"||wrcontrol_reg!="INCLOCK"||
       rdaddress_reg!="UNREGISTERED"||rdcontrol_reg!="UNREGISTERED"||outdata_reg!="UNREGISTERED")
        $fatal(1,"unsupported altdpram test model configuration");
end
endmodule
