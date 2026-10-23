// SPDX-License-Identifier: GPL-3.0-or-later
// (C)2016-2024 Revanth Kamaraj <revanth91kamaraj@gmail.com>
// Shared cache-hit and fill load formatting, moved from zap_dcache_fsm.
function automatic [31:0] ld_transform ( input [31:0] d, input [5:0] f );
        logic [7:0]  b;
        logic [15:0] h;

        case ( f[5:4] )
        2'd0:    b = d[7:0];
        2'd1:    b = d[15:8];
        2'd2:    b = d[23:16];
        default: b = d[31:24];
        endcase

        h = f[5] ? d[31:16] : d[15:0];

        if      ( f[2] ) ld_transform = {24'd0, b};
        else if ( f[3] ) ld_transform = {{24{b[7]}}, b};
        else if ( f[1] ) ld_transform = {{16{h[15]}}, h};
        else if ( f[0] ) ld_transform = {16'd0, h};
        else
        case ( f[5:4] )
        2'd0:    ld_transform = d;
        2'd1:    ld_transform = {d[7:0],  d[31:8]};
        2'd2:    ld_transform = {d[15:0], d[31:16]};
        default: ld_transform = {d[23:0], d[31:24]};
        endcase
endfunction
