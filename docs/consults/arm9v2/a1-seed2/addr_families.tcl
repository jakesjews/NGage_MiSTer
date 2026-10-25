# quartus_sta -t addr_families.tcl: the address-to-TLB and address-to-cache
# families of the 104 MHz plan, at the two slow corners
project_open cpu_trial
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection op [get_available_operating_conditions] {
    set_operating_conditions $op
    update_timing_netlist
    set name [get_operating_conditions_info -display_name $op]
    if {![string match "Slow*" $name]} { continue }
    set tag [string map {" " _} $name]
    set tlb [get_registers -nowarn {*u_data_cache|u_zap_tlb|*}]
    set dc  [get_registers -nowarn {*u_data_cache|*u_zap_cache_tag_ram|*}]
    set a   [get_registers -nowarn {*u_execute|a*}]
    foreach {fam from to} [list tlb_any {} $tlb tlb_from_a $a $tlb cache_from_a $a $dc] {
        if {$from eq {}} {
            set p [get_timing_paths -setup -to $to -npaths 1]
        } else {
            set p [get_timing_paths -setup -from $from -to $to -npaths 1]
        }
        foreach_in_collection x $p {
            puts "FAMILY $fam $name slack [get_path_info -slack $x] from [get_node_info -name [get_path_info -from $x]] to [get_node_info -name [get_path_info -to $x]] data [get_path_info -data_delay $x]"
        }
        if {$from eq {}} {
            report_timing -setup -to $to -npaths 1 -detail full_path -file "output_files/addr_family_${fam}_${tag}.txt"
        } else {
            report_timing -setup -from $from -to $to -npaths 1 -detail full_path -file "output_files/addr_family_${fam}_${tag}.txt"
        }
    }
}
project_close
