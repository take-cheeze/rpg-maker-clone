# Low-speed GPIO stub for the Maix Amigo Renode LCD capture (see
# amigo.repl.template and app/maix/README.md "LCD capture").
#
# gpio_set_pin asserts dir == 1, but plain Tags drop the direction write
# gpio_set_drive_mode just made -- remembering every register keeps the
# assert passing, and lets the DMA hook sample the live DC bit
# (data-output, low-speed GPIO 7, SIPEED_ST7789_DCX_GPIONUM) straight off
# this model.
if request.IsInit:
    gpio_regs = {}
elif request.IsRead:
    request.Value = gpio_regs.get(request.Offset, 0)
elif request.IsWrite:
    gpio_regs[request.Offset] = request.Value & 0xFFFFFFFF
