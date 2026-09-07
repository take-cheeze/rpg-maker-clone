//
// Copyright (c) 2010-2026 Antmicro
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
// A SAMD51 SERCOM instance configured in SPI master mode. SERCOM is a
// shared IP block (UART/SPI/I2C depending on CTRLA.MODE) -- this models the
// SPI-mode register subset only, since that is all this repo's Wio Terminal
// port (docs/adr/0094) needs: no upstream Renode peripheral covers SERCOM in
// any mode (SPI.SAM_SPI is an unrelated classic SAM4/SAME70 peripheral,
// checked against source rather than assumed).
//
// Modelled as instantaneous: writing DATA immediately calls Transmit() on
// whatever ISPIPeripheral is attached and DRE/TXC/RXC read back as always
// set once the peripheral is enabled, rather than tracking real baud-rate
// timing -- this repo's firmware polls those bits in a tight loop expecting
// them to be ready, exactly what every register stub in wio_terminal.repl
// (app/wio/renode/README.md) was already faking one register at a time; a
// real controller class makes that correct instead of coincidental, and is
// what actually lets a device attached via .repl receive real bytes.
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure;
using Antmicro.Renode.Core.Structure.Registers;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.SPI
{
    public class SAMD51_SERCOM_SPI : NullRegistrationPointPeripheralContainer<ISPIPeripheral>, IDoubleWordPeripheral, IProvidesRegisterCollection<DoubleWordRegisterCollection>, IKnownSize
    {
        public SAMD51_SERCOM_SPI(IMachine machine) : base(machine)
        {
            RegistersCollection = new DoubleWordRegisterCollection(this);
            DefineRegisters();
        }

        public override void Reset()
        {
            RegistersCollection.Reset();
            enabled = false;
            lastReceived = 0;
        }

        public uint ReadDoubleWord(long offset) => RegistersCollection.Read(offset);

        public void WriteDoubleWord(long offset, uint value) => RegistersCollection.Write(offset, value);

        public DoubleWordRegisterCollection RegistersCollection { get; }

        public long Size => 0x30;

        private void DefineRegisters()
        {
            Registers.CtrlA.Define(this)
                .WithFlag(0, FieldMode.Write, name: "SWRST", writeCallback: (_, value) =>
                {
                    if(value)
                    {
                        Reset();
                    }
                })
                .WithFlag(1, out enabledFlag, name: "ENABLE",
                    writeCallback: (_, value) => enabled = value)
                .WithIgnoredBits(2, 30)
            ;

            Registers.CtrlB.Define(this);
            Registers.Baud.Define(this);

            Registers.IntFlag.Define(this)
                .WithFlag(0, FieldMode.Read, name: "DRE", valueProviderCallback: _ => enabled)
                .WithFlag(1, FieldMode.Read, name: "TXC", valueProviderCallback: _ => enabled)
                .WithFlag(2, FieldMode.Read, name: "RXC", valueProviderCallback: _ => enabled)
                .WithIgnoredBits(3, 29)
            ;

            // Always reports "not busy": this model applies every CTRLA/ENABLE
            // change synchronously rather than tracking real clock-domain sync.
            Registers.SyncBusy.Define(this);

            Registers.Data.Define(this)
                .WithValueField(0, 8, name: "DATA",
                    valueProviderCallback: _ => lastReceived,
                    writeCallback: (_, value) =>
                    {
                        if(!enabled)
                        {
                            this.Log(LogLevel.Warning, "Wrote DATA while SERCOM is disabled");
                            return;
                        }
                        if(RegisteredPeripheral == null)
                        {
                            this.Log(LogLevel.Warning, "Wrote DATA with no device attached");
                            lastReceived = 0;
                            return;
                        }
                        lastReceived = RegisteredPeripheral.Transmit((byte)value);
                    })
                .WithIgnoredBits(8, 24)
            ;
        }

        private IFlagRegisterField enabledFlag;
        private bool enabled;
        private byte lastReceived;

        private enum Registers : long
        {
            CtrlA = 0x00,
            CtrlB = 0x04,
            Baud = 0x0C,
            IntFlag = 0x18,
            SyncBusy = 0x1C,
            Data = 0x28,
        }
    }
}
