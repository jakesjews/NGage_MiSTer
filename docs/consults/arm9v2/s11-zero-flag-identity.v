module proof(input [31:0] a,b,input cin);
wire [31:0] sum=a+b+cin;
wire zero_parallel=(a^b)=={(a[30:0]|b[30:0]),cin};
always @* assert((sum==0)==zero_parallel);
endmodule
