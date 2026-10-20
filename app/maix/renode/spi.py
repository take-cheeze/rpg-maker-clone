# SPI0 stub for the Maix Amigo Renode LCD capture (see amigo.repl.template
# and app/maix/README.md "LCD capture").
#
# Status reads answer 0x06 (TX FIFO not full, not busy) -- the driver's
# ((sr & 0x05) != 0x04) spin is what that satisfies. Everything else is
# ignored on write, zero on read. The actual capture happens in
# dma_hook.py's hook (which appends `D` lines itself -- bus writes from
# hooks never reach Python peripherals, so the snoop cannot live here).
if request.IsInit:
    spi_regs = {}
elif request.IsRead:
    if request.Offset == 0x28:
        request.Value = 0x06
    else:
        request.Value = spi_regs.get(request.Offset, 0)
elif request.IsWrite:
    spi_regs[request.Offset] = request.Value & 0xFFFFFFFF
