# quartus_sta -t report.tcl: worst paths per corner after the compile
project_open cpu_trial
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection op [get_available_operating_conditions] {
	set_operating_conditions $op
	update_timing_netlist
	set name [get_operating_conditions_info -display_name $op]
	set s [get_timing_paths -setup -npaths 1]
	foreach_in_collection p $s {
		puts "CORNER $name setup slack [get_path_info -slack $p]"
	}
	foreach_in_collection p [get_timing_paths -hold -npaths 1] {
		puts "HOLD $name hold slack [get_path_info -slack $p]"
	}
	report_timing -setup -npaths 12 -detail summary -file "output_files/paths_[string map {" " _} $name].txt"
}
project_close
