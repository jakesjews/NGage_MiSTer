# quartus_sta -t b_paths.tcl PROJECT: lane B's paths at the slow 100 C corner
set proj [lindex $quartus(args) 0]
project_open $proj
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection op [get_available_operating_conditions] {
    set name [get_operating_conditions_info -display_name $op]
    if {$name ne "Slow 1100mV 100C Model"} { continue }
    set_operating_conditions $op
    update_timing_netlist
    set word  [get_registers -nowarn {*u_data_cache|tr_cache_words*}]
    set mrec  [get_registers -nowarn {*|g_arm9.u_arm9_core|m[*}]
    set skid  [get_registers -nowarn {*|g_arm9.u_arm9_core|skid[*}]
    set flags [get_registers -nowarn {*u_execute|flags*}]
    set arec  [get_registers -nowarn {*u_execute|a[*}]
    set late  [get_registers -nowarn {*u_execute|a[1[0-9]]}]
    set live  [get_registers -nowarn {*u_zap_cache_fsm|o_live_lookup*}]
    set trust [get_registers -nowarn {*u_zap_cache_fsm|o_live_trust*}]
    set cand  [get_registers -nowarn {*|g_arm9.u_arm9_core|w_hit_candidate*}]
    set cpu   [get_registers -nowarn {*|g_arm9.u_arm9_core|*}]
    foreach {tag from to} [list word_to_m $word $mrec word_to_skid $word $skid word_to_flags $word $flags word_to_a $word $arec \
                                late_to_m $late $mrec late_to_flags $late $flags live_to_cpu $live $cpu trust_to_cpu $trust $cpu cand_to_cpu $cand $cpu] {
        if {[get_collection_size $from] == 0 || [get_collection_size $to] == 0} { puts "BPATH $tag none"; continue }
        foreach_in_collection p [get_timing_paths -setup -from $from -to $to -npaths 1] {
            puts "BPATH $tag slack [get_path_info -slack $p] from [get_node_info -name [get_path_info -from $p]] to [get_node_info -name [get_path_info -to $p]] data [get_path_info -data_delay $p]"
        }
        report_timing -setup -from $from -to $to -npaths 1 -detail full_path -file "output_files/bpath_${tag}.txt"
    }
}
project_close
