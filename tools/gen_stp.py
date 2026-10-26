#!/usr/bin/env python3
"""Generate a SignalTap II file (.stp) for Quartus 17 from a small JSON spec,
so a probe set and trigger can be built headlessly on the server.

Spec (JSON):
  {"clock": "emu:emu|pll:pll|pll_0002:pll_inst|altera_pll:altera_pll_i|outclk_wire[0]",
   "depth": 1024, "ram": "M10K",
   "instances": [
     {"name": "flash", "position": "pre", "depth": 1024, "ram": "M10K",
      "nodes": [["emu:emu|stp_va_q", 32], ["emu:emu|stp_trig_q", 1], ...],
      "trigger": {"emu:emu|stp_trig_q": "1"},
      "store":   {"emu:emu|stp_store_q": "1"}}]}
A node is [name, width]; width 1 is a scalar "name", wider ones are the bits
"name[i]". "trigger" maps a scalar node, or one bit of a bus as "name[i]", to
"1"/"0"/"R"/"F" (high, low, rising edge, falling edge); the conditions are
ANDed; nodes not listed are don't care. An optional "store" map of the same
form makes the storage qualifier conditional: a sample is kept only on cycles
that match. "depth"/"ram"/"position" may be set per instance (the top-level
values are the defaults). Usage: gen_stp.py SPEC.json OUT.stp

Encoding notes (2026-10-25, from files the Quartus 17 GUI wrote): the wires of
the signal vectors carry no type attribute; a condition lives as TEXT inside
its <level> element ('node' == high && 'other' == falling edge) as well as in
the per-node level-0 attributes; the storage qualifier's condition sits the
same way inside the first <storage_qualifier_level>; storage_mode is "off"
for a continuous capture. The earlier generator wrote none of the text
expressions, and typed the wires "combinatorial": Analysis & Synthesis then
preserved no pre-synthesis tap, the nodes (and the acquisition clock) were
looked up in the post-synthesis netlist by name, and most of them, the clock
included, came out "missing" and were tied to ground. Tap registers that are
kept through synthesis ((* preserve, noprune *)) and name the clock by a net
that survives synthesis (the PLL's outclk_wire) so either lookup finds them.
"""
import json, sys
from xml.sax.saxutils import quoteattr as q, escape

spec = json.load(open(sys.argv[1]))
clock = spec["clock"]
LEVEL = {"1": "high", "0": "low", "R": "rising_edge", "F": "falling_edge", "X": "dont_care"}
TEXT = {"1": "high", "0": "low", "R": "rising edge", "F": "falling edge"}

def bits(name, width):
    return [name] if width == 1 else [f"{name}[{i}]" for i in range(width)]

def expr(cond):
    """The textual condition the run-time flow evaluates."""
    return " && ".join(f"'{n}' == {TEXT[v]}" for n, v in cond.items())

def check(cond, wires, what, inst):
    for n, v in cond.items():
        if n not in wires:
            sys.exit(f"{inst}: {what} names {n!r}, which is not a probed scalar or bus bit")
        if v not in TEXT:
            sys.exit(f"{inst}: {what} level {v!r} for {n}: use 1/0/R/F")

out = ['<session jtag_chain="" jtag_device="" sof_file="">', '  <display_tree gui_logging_enabled="0">']
for k, inst in enumerate(spec["instances"]):
    out.append(f'    <display_branch instance={q(inst["name"])} log="USE_GLOBAL_TEMP" signal_set="USE_GLOBAL_TEMP" trigger="USE_GLOBAL_TEMP"/>')
out += ['  </display_tree>', '  <mnemonics/>']
total = 0
for k, inst in enumerate(spec["instances"]):
    name = inst["name"]; nodes = inst["nodes"]; trig = inst.get("trigger", {}); store = inst.get("store", {})
    depth = int(inst.get("depth", spec.get("depth", 2048))); ram = inst.get("ram", spec.get("ram", "AUTO"))
    pos = inst.get("position", "pre")
    wires = [w for n, wd in nodes for w in bits(n, wd)]
    total += len(wires)
    check(trig, wires, "trigger", name); check(store, wires, "store", name)
    out.append(f'  <instance enabled="true" entity_name="sld_signaltap" is_auto_node="yes" is_expanded="true" name={q(name)} source_file="sld_signaltap.vhd">')
    out.append(f'    <node_ip_info instance_id="{k}" mfg_id="110" node_id="0" version="6"/>')
    out.append(f'    <signal_set global_temp="1" name="signal_set: {name}">')
    out.append(f'      <clock name={q(clock)} polarity="posedge" tap_mode="classic"/>')
    out.append(f'      <config pipeline_level="0" ram_type="{ram}" reserved_data_nodes="0" reserved_storage_qualifier_nodes="0" reserved_trigger_nodes="0" sample_depth="{depth}" trigger_in_enable="no" trigger_out_enable="no"/>')
    out.append('      <top_entity/>')
    out.append('      <signal_vec>')
    for sec in ("trigger_input_vec", "data_input_vec", "storage_qualifier_input_vec"):
        out.append(f'        <{sec}>')
        for w in wires:
            out.append(f'          <wire name={q(w)} tap_mode="classic"/>')
        out.append(f'        </{sec}>')
    out.append('      </signal_vec>')
    out.append('      <presentation>')
    out.append('        <unified_setup_data_view>')
    idx = 0
    def node(i, w):
        attrs = [f'data_index="{i}"', 'duplicate_name_allowed="false"', 'is_data_input="true"', 'is_node_valid="true"',
                 'is_selected="false"', 'is_storage_input="true"', 'is_trigger_input="true"']
        if w in trig: attrs.append(f'level-0="{LEVEL[trig[w]]}"')
        attrs.append(f'name={q(w)}')
        if w in store: attrs.append(f'storage-0="{LEVEL[store[w]]}"')
        attrs += [f'storage_index="{i}"', 'tap_mode="classic"', f'trigger_index="{i}"', 'type="unknown"']
        return "<node " + " ".join(attrs) + "/>"
    for n, wd in nodes:
        if wd == 1:
            out.append("          " + node(idx, n)); idx += 1
        else:
            out.append(f'          <bus is_selected="false" level-0="alt_or" name={q(n + f"[{wd-1}..0]")} order="msb_to_lsb" type="register">')
            for i in reversed(range(wd)):
                out.append("            " + node(idx + i, f"{n}[{i}]"))
            out.append('          </bus>')
            idx += wd
    out.append('        </unified_setup_data_view>')
    out.append('        <trigger_in_editor/>')
    out.append('        <trigger_out_editor/>')
    out.append('      </presentation>')
    smode = "conditional" if store else "off"
    out.append(f'      <trigger attribute_mem_mode="false" gap_record="true" global_temp="1" name="trigger: {name}" position="{pos}" power_up_trigger_mode="false" record_data_gap="true" segment_size="{depth}" storage_mode="{smode}" storage_qualifier_disabled="no" storage_qualifier_port_is_pin="true" storage_qualifier_port_name="auto_stp_external_storage_qualifier" storage_qualifier_port_tap_mode="classic" trigger_type="circular">')
    out.append(f'        <power_up_trigger position="{pos}" storage_qualifier_disabled="no"/>')
    out.append('        <events use_custom_flow_control="no">')
    out.append(f'          <level enabled="yes" name="condition1" type="basic">{escape(expr(trig))}')
    out.append('            <power_up enabled="yes">')
    out.append('            </power_up>')
    out.append('            <op_node/>')
    out.append('          </level>')
    out.append('        </events>')
    ones = "1" * len(wires)
    out.append('        <storage_qualifier_events>')
    out.append(f'          <transitional>{ones}')
    out.append(f'            <pwr_up_transitional>{ones}</pwr_up_transitional>')
    out.append('          </transitional>')
    for lvl in range(3):
        out.append(f'          <storage_qualifier_level type="basic">{escape(expr(store)) if lvl == 0 else ""}')
        out.append('            <power_up>')
        out.append('            </power_up>')
        out.append('            <op_node/>')
        out.append('          </storage_qualifier_level>')
    out.append('        </storage_qualifier_events>')
    out.append('      </trigger>')
    out.append('    </signal_set>')
    out.append('  </instance>')
out.append('  <global_info>')
out.append('    <single attribute="active instance" value="0"/>')
out.append('  </global_info>')
out.append('</session>')
open(sys.argv[2], "w").write("\n".join(out) + "\n")
print(f"wrote {sys.argv[2]}: {total} bits in {len(spec['instances'])} instance(s)")
