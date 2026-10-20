# PlatformIO pre-script: bounds framework-maixduino's I2C wait loops with a
# real timeout.
#
# TwoWire::writeTransmission/readTransmission (Wire.cpp) spin on the K210's
# I2C status/FIFO registers with only a tx_abrt_source check -- no timeout,
# despite TwoWire::setTimeOut/_timeOutMillis existing in the class and never
# being read anywhere. An address that can't cleanly NACK (confirmed on real
# Maix Amigo hardware: an I2C1 scan, and later a specific known-but-flaky
# device address, both wedged the board solid -- no crash, no further
# serial output, sometimes recovered by a watchdog-driven reboot loop,
# sometimes not at all) spins there forever. Once wedged, even a full CPU
# reset doesn't clear it -- only cutting power to the bus's external chips
# does -- so this isn't a "just add a retry in application code" bug; the
# driver itself has to stop waiting.
#
# This patches both wait loops (the FIFO/ACTIVITY spin in writeTransmission,
# and the combined read/ack spin in readTransmission) to bail out after
# kI2cTimeoutMs, resetting the I2C peripheral (disable/re-enable, the same
# sequence TwoWire::begin/setClock already use) before returning a new
# error code (5, distinct from the existing abort path's 4) so a caller can
# tell "wedged" apart from "device NACKed". Idempotent (checks for its own
# marker) so re-running it -- every build does -- is a no-op once applied.
#
# Patches the *installed* package in-place (there is no way to fork/vendor
# just one file of a PlatformIO framework package short of vendoring the
# whole thing, and app/maix/add_amigo_variant.py already established the
# pattern of pre-scripts covering for framework-maixduino gaps): safe
# because it is idempotent and applied fresh by every build, including CI.

from os.path import isfile, join

Import("env")

MARKER = "__i2c_patch_deadline"

WRITE_OLD = """    while ( (i2c_adapter->status & I2C_STATUS_ACTIVITY) ||
            !(i2c_adapter->status & I2C_STATUS_TFE) )
    {
        if (i2c_adapter->tx_abrt_source != 0)
        {
            i2c_adapter->clr_tx_abrt;
            usleep(10);
            return 4;
        }
    }

    return 0;
}

int
TwoWire::readTransmission"""

WRITE_NEW = """    {
        uint32_t __i2c_patch_deadline = millis() + kI2cTimeoutMs;
        while ( (i2c_adapter->status & I2C_STATUS_ACTIVITY) ||
                !(i2c_adapter->status & I2C_STATUS_TFE) )
        {
            if (i2c_adapter->tx_abrt_source != 0)
            {
                i2c_adapter->clr_tx_abrt;
                usleep(10);
                return 4;
            }
            if (millis() > __i2c_patch_deadline)
            {
                i2c_adapter->enable = 0;
                i2c_adapter->enable = I2C_ENABLE_ENABLE;
                return 5;
            }
        }
    }

    return 0;
}

int
TwoWire::readTransmission"""

READ_OLD = """    while (receive_buf_len || rx_len)
    {
        fifo_len = i2c_adapter->rxflr;"""

READ_NEW = """    uint32_t __i2c_patch_deadline = millis() + kI2cTimeoutMs;
    while (receive_buf_len || rx_len)
    {
        if (millis() > __i2c_patch_deadline)
        {
            i2c_adapter->enable = 0;
            i2c_adapter->enable = I2C_ENABLE_ENABLE;
            return 5;
        }
        fifo_len = i2c_adapter->rxflr;"""

HEADER_OLD = '#include "Wire.h"'
HEADER_NEW = '#include "Wire.h"\n\n// See app/maix/patch_wire_i2c_timeout.py.\nstatic constexpr uint32_t kI2cTimeoutMs = 50;\n// __i2c_patch_deadline'


def patch_wire_cpp():
    framework_dir = env.PioPlatform().get_package_dir("framework-maixduino")
    if not framework_dir:
        return
    wire_cpp = join(framework_dir, "libraries", "Wire", "src", "Wire.cpp")
    if not isfile(wire_cpp):
        return

    with open(wire_cpp, "r") as f:
        content = f.read()

    if MARKER in content:
        return  # already patched

    assert HEADER_OLD in content, "Wire.cpp header include not found -- framework version changed?"
    assert WRITE_OLD in content, "Wire.cpp writeTransmission wait loop not found -- framework version changed?"
    assert READ_OLD in content, "Wire.cpp readTransmission wait loop not found -- framework version changed?"

    content = content.replace(HEADER_OLD, HEADER_NEW, 1)
    content = content.replace(WRITE_OLD, WRITE_NEW, 1)
    content = content.replace(READ_OLD, READ_NEW, 1)

    with open(wire_cpp, "w") as f:
        f.write(content)


patch_wire_cpp()
