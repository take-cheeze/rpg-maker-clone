//
// This file is licensed under the MIT License.
//
// The SAMD51 QSPI controller in serial-memory mode with the Wio Terminal's
// 32 Mbit NOR flash behind it, as far as app/wio/src/wio_qspi.c drives them:
// an instruction frame, its data phase as CPU accesses to the AHB window
// (a MappedMemory, so the code runs from it at full speed), then LASTXFER.
// A data phase reads or writes the window itself, so the model puts a status
// register's bytes where the read lands and puts back what it covered at
// LASTXFER, and turns a page program into what NOR does (the old bytes ANDed
// with the new). Erase and program need the write-enable latch and keep the
// chip busy for their typical time (W25Q32JV: 45 ms a 4 KB sector, 0.4 ms a
// page) of virtual time, as the status register shows. EraseCount and
// ProgramCount count what reached the flash.
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Extensions;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals.SPI
{
    public class SAMD51_QSPI : IDoubleWordPeripheral, IBytePeripheral, IKnownSize
    {
        public SAMD51_QSPI(IMachine machine, ulong window = 0x04000000, uint size = 0x400000,
                           ulong sectorEraseMicros = 45000, ulong pageProgramMicros = 400)
        {
            this.machine = machine;
            this.window = window;
            this.size = size;
            sectorErase = TimeInterval.FromMicroseconds(sectorEraseMicros);
            pageProgram = TimeInterval.FromMicroseconds(pageProgramMicros);
            Reset();
        }

        public void Reset()
        {
            for(var i = 0; i < regs.Length; i++)
            {
                regs[i] = 0;
            }
            saved = null;
            writeEnabled = false;
            busyUntil = TimeInterval.Empty;
        }

        public long Size => 0x48;

        public ulong EraseCount { get; private set; }

        public ulong ProgramCount { get; private set; }

        public uint ReadDoubleWord(long offset)
        {
            switch(offset)
            {
            case IntFlag:
                // Instantaneous: every transfer is over by the time it is polled.
                return InstrEnd | CsRise | 0x7;
            case Status:
                return ((regs[CtrlA / 4] & Enable) != 0 ? Enable : 0u) | CsStatus;
            default:
                return offset >= 0 && offset < Size ? regs[offset / 4] : 0;
            }
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            if(offset < 0 || offset >= Size)
            {
                return;
            }
            switch(offset)
            {
            case CtrlA:
                if((value & 1) != 0)
                {
                    Reset();
                    return;
                }
                regs[CtrlA / 4] = value & ~LastXfer;
                if((value & LastXfer) != 0)
                {
                    Finish();
                }
                return;
            case IntFlag:
                return;
            case InstrFrame:
                regs[InstrFrame / 4] = value;
                Begin(value);
                return;
            default:
                regs[offset / 4] = value;
                return;
            }
        }

        public byte ReadByte(long offset) => this.ReadByteUsingDoubleWord(offset);

        public void WriteByte(long offset, byte value) => this.WriteByteUsingDoubleWord(offset, value);

        private TimeInterval Now => machine.ElapsedVirtualTime.TimeElapsed;

        private bool Busy => Now < busyUntil;

        private uint Instruction => regs[InstrCtrl / 4] & 0xff;

        private uint Address => regs[InstrAddr / 4] & 0xffffff;

        // The transfer type and whether it has a data phase, of the frame being run.
        private uint Type(uint frame) => (frame >> 12) & 3;

        private void Begin(uint frame)
        {
            saved = null;
            if(Type(frame) == ReadMemory || (frame & DataEn) == 0)
            {
                return;
            }
            var at = (frame & AddrEn) != 0 ? Address : 0u;
            if(at + PageSize > size)
            {
                this.Log(LogLevel.Error, "QSPI: a data phase at 0x{0:X} runs past the flash", at);
                return;
            }
            saved = machine.SystemBus.ReadBytes(window + at, (int)PageSize);
            savedAt = at;
            if(Type(frame) == Read)
            {
                machine.SystemBus.WriteBytes(StatusBytes(), window + at);
            }
        }

        private byte[] StatusBytes()
        {
            var bytes = new byte[PageSize];
            switch(Instruction)
            {
            case 0x05: // status register 1: BUSY, WEL
                bytes[0] = (byte)((Busy ? 1 : 0) | (writeEnabled ? 2 : 0));
                break;
            case 0x35: // status register 2: QE, set on this board
                bytes[0] = 0x02;
                break;
            case 0x9F: // JEDEC ID: Winbond, W25Q32
                bytes[0] = 0xEF;
                bytes[1] = 0x40;
                bytes[2] = 0x16;
                break;
            default:
                this.Log(LogLevel.Warning, "QSPI: read instruction 0x{0:X2} is not modelled", Instruction);
                break;
            }
            return bytes;
        }

        private void Finish()
        {
            var frame = regs[InstrFrame / 4];
            if(Type(frame) == ReadMemory)
            {
                return;
            }
            var instr = Instruction;
            var written = saved != null ? machine.SystemBus.ReadBytes(window + savedAt, (int)PageSize) : null;
            // The data phase never stays in the window by itself: a program changes it below.
            if(saved != null)
            {
                machine.SystemBus.WriteBytes(saved, window + savedAt);
            }
            // A read's data phase is a register read; any other frame is a command, whatever its transfer type
            // (wio_qspi.c sends those without data as reads).
            if(Type(frame) == Read && (frame & DataEn) != 0)
            {
                return;
            }
            if(Busy)
            {
                this.Log(LogLevel.Error, "QSPI: instruction 0x{0:X2} while the flash is busy: ignored", instr);
                return;
            }
            switch(instr)
            {
            case 0x06:
                writeEnabled = true;
                return;
            case 0x04:
                writeEnabled = false;
                return;
            }
            if(!writeEnabled)
            {
                this.Log(LogLevel.Error, "QSPI: instruction 0x{0:X2} without write enable: ignored", instr);
                return;
            }
            writeEnabled = false;
            switch(instr)
            {
            case 0x20:
                Erase(Address & ~0xfffu, 0x1000);
                return;
            case 0x52:
                Erase(Address & ~0x7fffu, 0x8000);
                return;
            case 0xD8:
                Erase(Address & ~0xffffu, 0x10000);
                return;
            case 0x02:
                if(written == null)
                {
                    this.Log(LogLevel.Error, "QSPI: a page program without data");
                    return;
                }
                for(var i = 0; i < PageSize; i++)
                {
                    written[i] &= saved[i];
                }
                machine.SystemBus.WriteBytes(written, window + savedAt);
                ProgramCount++;
                busyUntil = Now + pageProgram;
                return;
            case 0x31:
                // Quad Enable is already set: the model's status register 2 does not change.
                busyUntil = Now + pageProgram;
                return;
            default:
                this.Log(LogLevel.Warning, "QSPI: instruction 0x{0:X2} is not modelled", instr);
                return;
            }
        }

        private void Erase(uint at, uint length)
        {
            if(at + length > size)
            {
                this.Log(LogLevel.Error, "QSPI: an erase at 0x{0:X} runs past the flash", at);
                return;
            }
            var ones = new byte[length];
            for(var i = 0; i < ones.Length; i++)
            {
                ones[i] = 0xff;
            }
            machine.SystemBus.WriteBytes(ones, window + at);
            EraseCount += length / 0x1000;
            busyUntil = Now + sectorErase * (ulong)(length / 0x1000);
        }

        private readonly IMachine machine;
        private readonly ulong window;
        private readonly uint size;
        private readonly TimeInterval sectorErase;
        private readonly TimeInterval pageProgram;
        private readonly uint[] regs = new uint[0x48 / 4];
        private byte[] saved;
        private uint savedAt;
        private bool writeEnabled;
        private TimeInterval busyUntil;

        private const long CtrlA = 0x00;
        private const long IntFlag = 0x1C;
        private const long Status = 0x20;
        private const long InstrAddr = 0x30;
        private const long InstrCtrl = 0x34;
        private const long InstrFrame = 0x38;
        private const uint Enable = 1u << 1;
        private const uint LastXfer = 1u << 24;
        private const uint InstrEnd = 1u << 10;
        private const uint CsRise = 1u << 8;
        private const uint CsStatus = 1u << 9;
        private const uint AddrEn = 1u << 5;
        private const uint DataEn = 1u << 7;
        private const uint Read = 0;
        private const uint ReadMemory = 1;
        private const uint PageSize = 256;
    }
}
