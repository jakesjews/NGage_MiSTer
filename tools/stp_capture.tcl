# Headless SignalTap acquisition on the server's JTAG server.
#   docker exec ngage-jtag /opt/intelFPGA_lite/quartus/bin/quartus_stp -t /project/tools/stp_capture.tcl STP TIMEOUT_S INSTANCES [HARDWARE_PATTERN]
# INSTANCES is one instance name or several separated by commas; they are armed
# together (run_multiple_start/end), each with its own trigger (the names
# tools/gen_stp.py wrote: "signal_set: X" and "trigger: X"). Waits up to
# TIMEOUT_S seconds; close_session then writes whatever was captured into STP
# as data log "log_1" of each instance (there is no save_session in this
# package: a script that calls one dies before the file is written); the
# caller decodes the XML (tools/stp_decode.py).
package require ::quartus::stp
lassign $quartus(args) stp timeout insts hwpat
if {$hwpat eq ""} { set hwpat "*" }
set hw ""
foreach h [get_hardware_names] { if {[string match $hwpat $h]} { set hw $h; break } }
if {$hw eq ""} { puts "no JTAG hardware matching $hwpat: [get_hardware_names]"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSEBA6*" $d] || [string match "*5CSEMA6*" $d]} { set dev $d; break } }
if {$dev eq ""} { puts "no 5CSEBA6 on $hw: [get_device_names -hardware_name $hw]"; exit 1 }
puts "hardware: $hw  device: $dev"
open_session -name $stp
set insts [split $insts ","]
set rc 0
if {[llength $insts] == 1} {
    set i [lindex $insts 0]
    set rc [catch {run -hardware $hw -device $dev -instance $i -signal_set "signal_set: $i" -trigger "trigger: $i" -data_log log_1 -timeout $timeout} msg]
    puts "run $i: $msg"
} else {
    set rc [catch {run_multiple_start} msg]
    puts "run_multiple_start: $msg"
    foreach i $insts {
        set r [catch {run -hardware $hw -device $dev -instance $i -signal_set "signal_set: $i" -trigger "trigger: $i" -data_log log_1 -timeout $timeout} msg]
        puts "run $i: $msg"
        if {$r} { set rc $r }
    }
    set r [catch {run_multiple_end} msg]
    puts "run_multiple_end: $msg"
    if {$r} { set rc $r }
}
close_session
exit $rc
