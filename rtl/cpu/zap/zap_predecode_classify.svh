// ARM925T: shared classification of encodings that predecode must trap.
// Included inside predecode and the sequencer after zap_localparams.svh;
// V4T belongs to the enclosing module. Deliberately no global include guard.
function automatic classify_undefined(input [34:0] x, input thumb);
        classify_undefined = (!thumb && x[27:25] == 3'b011 && x[4]) || V4T && (
                (!thumb && x[31:28] == NV)        ||
                (thumb && x[31:25] == 7'b1111_101) ||
                x[31:0] ==? CLZ_INSTRUCTION              ||
                x[31:0] ==? BLX2                         ||
                x[31:0] ==? BKPT                         ||
                x[31:0] ==? QADD                         ||
                x[31:0] ==? QSUB                         ||
                x[31:0] ==? QDADD                        ||
                x[31:0] ==? QDSUB                        ||
                x[31:0] ==? SMLAxy                       ||
                x[31:0] ==? SMLAWy                       ||
                x[31:0] ==? SMLALxy                      ||
                x[31:0] ==? SMULWy                       ||
                x[31:0] ==? SMULxy                       ||
                (x[27:25] == 3'b000 && !x[20] && x[7:4] ==? 4'b11?1) );
endfunction
