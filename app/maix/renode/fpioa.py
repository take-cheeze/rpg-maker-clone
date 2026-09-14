# FPIOA stub for the Maix Amigo Renode boot (see amigo.repl.template).
#
# The Kendryte SDK routes every pin through fpioa_set_function(io, func) and
# later looks the routing back up with fpioa_get_io_by_function(func), which
# scans io[].ch_sel and asserts (-1) when nothing matches. A plain sysbus Tag
# answers every read as zero, so the very first Arduino pinMode (the green LED
# in the P0 firmware's setup()) hangs in that assert. Remembering each routed
# function word and answering reads back is the whole model -- enough for the
# boot path, which never needs electrical fidelity, only its own writes back.
if request.IsInit:
    fpioa_ch_sel = {}
elif request.IsRead:
    request.Value = fpioa_ch_sel.get(request.Offset, 0)
elif request.IsWrite:
    fpioa_ch_sel[request.Offset] = request.Value & 0xFFFFFFFF
