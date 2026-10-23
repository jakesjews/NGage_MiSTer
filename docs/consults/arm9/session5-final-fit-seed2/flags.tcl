project_open cpu_trial
create_timing_netlist
read_sdc
update_timing_netlist
# result_t flags occupy [187:156]; inspect all four architectural NZCV bits.
foreach {bit label} {184 v 185 c 186 z 187 n} {
    set patterns [list [format {*fast_1[%d]*} $bit] [format {*fast_1\[%d\]*} $bit]]
    foreach pattern $patterns {
        set regs [get_registers $pattern]
        puts "FLAGS_PATTERN $label $pattern count [get_collection_size $regs]"
        if {[get_collection_size $regs] > 0} {
            foreach_in_collection op [get_available_operating_conditions] {
                set_operating_conditions $op
                update_timing_netlist
                set name [get_operating_conditions_info -display_name $op]
                report_timing -setup -to $regs -npaths 4 -detail full_path -file "output_files/detail_execute_flags_${label}_[string map {" " _} $name].txt"
            }
            break
        }
    }
}
project_close
