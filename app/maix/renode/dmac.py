# AXI-DMAC stub for the Maix Amigo Renode LCD capture (see amigo.repl.template
# and app/maix/README.md "LCD capture").
#
# This peripheral only REMEMBERS registers (SAR/DAR/BLOCK_TS/CTL/CFG/chen
# per channel). A plain Tag cannot do even that: dmac_set_single_mode
# programs SAR/DAR before enabling, and the values must still be there when
# dma_hook.py's hook replays the transfer into the capture file.
if request.IsInit:
    dmac_regs = {}
elif request.IsRead:
    request.Value = dmac_regs.get(request.Offset, 0)
elif request.IsWrite:
    dmac_regs[request.Offset] = request.Value & 0xFFFFFFFFFFFFFFFF
