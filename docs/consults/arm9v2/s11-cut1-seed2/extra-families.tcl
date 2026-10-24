project_open cpu_trial
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection op [get_available_operating_conditions] {
 set_operating_conditions $op
 update_timing_netlist
 set name [get_operating_conditions_info -display_name $op]
 foreach {family pattern} {
  backend_m {*|g_arm9.u_arm9_core|m*}
  backend_skid {*|g_arm9.u_arm9_core|skid*}
  tlb_metadata {*u_data_cache|*u_zap_tlb|*g_short.valid*}
 } {
  set endpoints [get_registers -nowarn $pattern]
  if {[get_collection_size $endpoints] > 0} {
   report_timing -setup -to $endpoints -npaths 1 -detail full_path -file "output_files/detail_family_${family}_[string map {" " _} $name].txt"
  }
 }
}
project_close
