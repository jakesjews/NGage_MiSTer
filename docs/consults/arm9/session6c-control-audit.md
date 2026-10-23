# Control-boundary pass audit (before trial)

- F -> D: keep the registered fetch queue added in ae3b838. Word, Thumb
  translation, permission abort, pending-fill status and prediction metadata
  share the queue boundary. Valid derives only from registered queue state.
- D -> E: issue/admission no longer depends on decoded register readiness.
  The E record carries serial_ready_e. While held, E captures each bypass and
  the corresponding readiness before a serialized context consumes value_e.
  Fast consumers retain the existing local E forwarding/interlock.
- E -> M1 -> M2 -> W: existing result records already register validity,
  condition pass, register destinations, memory controls, mode, fault and data.
  Keep those records at their existing edges with dont_retime. Do not add a
  memory stage or alter load formatting/RAM/tag comparison.
- E/W -> fetch: register redirect event/target/Thumb state, predictor feedback
  and predictor clear. The decision edge still suppresses younger side effects
  on an older fault. clear_e_late/clear_pipe_late apply while fetch consumes the
  registered redirect, so a speculative D capture cannot execute.
- Block sequencer: use the registered block classification while active;
  register file/forward data and per-transfer readiness are unchanged.
- Physical stage boundaries: mark E decoded controls, instruction context,
  slow memory/writeback controls, fetch queue and result records dont_retime.
  Packed result/queue records retain data with control; their arithmetic and
  functional schedule are unchanged. Do not disable retiming globally or
  modify ZAP/execute/cache RTL.
- Retained handshake: cache requests/ack/retry and local ready/hold still
  determine whether the owning stage advances. No delayed acknowledgement or
  speculative store is introduced. The fit must determine the remaining cost
  of these local combinational handshake/forwarding cones.

Source for the register retiming attribute:
https://docs.altera.com/r/docs/683283/18.1/design-compilation-user-guide-quartus-prime-standard-edition/disabling-synthesis-netlist-optimizations-with-dont_retime-attribute
