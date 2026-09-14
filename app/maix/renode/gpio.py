# Low-speed GPIO stub for the Maix Amigo Renode boot (see amigo.repl.template).
#
# The LCD driver (Maixduino's st7789.c) routes a control pin, sets its drive
# mode to output, then drives it -- but gpio_set_pin asserts dir == 1 while a
# plain sysbus Tag drops the direction write gpio_set_drive_mode just made,
# so the pin reads back as input forever. Same remember-and-answer shape as
# fpioa.py (separate file because each Python peripheral instance needs its
# own globals): read-modify-write traffic stays coherent, and nothing here
# polls a status bit, so constant-zero Tag behaviour would be fine for every
# other GPIO register -- except direction, which this file carries.
if request.IsInit:
    gpio_regs = {}
elif request.IsRead:
    request.Value = gpio_regs.get(request.Offset, 0)
elif request.IsWrite:
    gpio_regs[request.Offset] = request.Value & 0xFFFFFFFF
