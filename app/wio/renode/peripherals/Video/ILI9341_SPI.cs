//
// Copyright (c) 2010-2026 Antmicro
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
// A 4-wire SPI ILI9341/compatible TFT panel: docs/adr/0094 P3 for this
// repo's Wio Terminal port. Attaches as an ISPIPeripheral to a
// SAMD51_SERCOM_SPI controller and a GPIO input (number 0) carries the D/C
// (data/command select) line -- a real pin on real hardware
// (LCD_DC/PORTC.6 on the Wio Terminal variant), not part of the SPI byte
// stream itself, so this needs the GPIO wired in .repl alongside the SPI
// registration point.
//
// Scope is deliberately narrow: only CASET/PASET/RAMWR (and MADCTL, whose
// parameter byte this only consumes without acting on -- the firmware
// already sizes its CASET/PASET window for the rotation it wants) are
// interpreted. Every other command byte just resets the "waiting for a new
// command" state without effect. This is not a general ILI9341 model; it is
// exactly what this firmware's own TFT_eSPI fork sends.
using System;
using System.IO;

using BigGustave;

using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.SPI;

namespace Antmicro.Renode.Peripherals.Video
{
    public class ILI9341_SPI : ISPIPeripheral, IGPIOReceiver
    {
        public ILI9341_SPI(int width = 320, int height = 240)
        {
            this.width = width;
            this.height = height;
            framebuffer = new byte[width, height, 3];
        }

        public void Reset()
        {
            dcIsData = false;
            currentCommand = null;
            paramIndex = 0;
            windowX0 = windowY0 = 0;
            windowX1 = (ushort)(width - 1);
            windowY1 = (ushort)(height - 1);
            cursorX = cursorY = 0;
            pixelHighByte = null;
        }

        // GPIO input number 0: the D/C pin. High (per this firmware's
        // TFT_Interface.h DC_D/DC_C macros) selects data, low selects
        // command -- the same polarity for every ILI9341-family 4-wire SPI
        // driver, not specific to this board.
        public void OnGPIO(int number, bool value)
        {
            if(number != 0)
            {
                this.Log(LogLevel.Warning, "Unexpected GPIO input {0}, only 0 (D/C) is wired", number);
                return;
            }
            dcIsData = value;
        }

        public byte Transmit(byte data)
        {
            if(!dcIsData)
            {
                // A new command byte always resets in-flight parameter
                // state, regardless of how the previous command's byte
                // count compares to what we expected -- robust to a
                // command this model does not track parameters for.
                currentCommand = data;
                paramIndex = 0;
                pixelHighByte = null;
                return 0;
            }

            switch(currentCommand)
            {
            case ColumnAddressSet:
                HandleWindowByte(data, ref windowX0, ref windowX1);
                break;
            case PageAddressSet:
                HandleWindowByte(data, ref windowY0, ref windowY1);
                break;
            case MemoryWrite:
                HandlePixelByte(data);
                break;
            default:
                // Init-sequence and other commands this model does not
                // act on (see ILI9341_Init.h) -- consume the byte, no
                // framebuffer effect.
                break;
            }
            return 0;
        }

        public void FinishTransmission()
        {
            // Deliberately not resetting paramIndex/pixelHighByte here: a
            // multi-tile pushImage keeps sending RAMWR data across many
            // short SPI transactions without re-issuing the RAMWR command
            // byte between them (auto-increment addressing is exactly the
            // ILI9341 feature that makes that legal), so a CS pulse between
            // them must not lose the cursor position.
        }

        // SaveFramebufferPng: a Renode monitor command (any public method on
        // a peripheral is callable from the Monitor), e.g.
        //   lcd SaveFramebufferPng "/tmp/frame.png"
        public void SaveFramebufferPng(string path)
        {
            var builder = PngBuilder.Create(width, height, false);
            for(var y = 0; y < height; y++)
            {
                for(var x = 0; x < width; x++)
                {
                    builder.SetPixel(framebuffer[x, y, 0], framebuffer[x, y, 1], framebuffer[x, y, 2], x, y);
                }
            }
            using(var stream = File.Create(path))
            {
                builder.Save(stream);
            }
            this.Log(LogLevel.Info, "Saved framebuffer to {0}", path);
        }

        private void HandleWindowByte(byte data, ref ushort start, ref ushort end)
        {
            // CASET/PASET: 4 parameter bytes, (start_hi, start_lo, end_hi, end_lo).
            switch(paramIndex)
            {
            case 0:
                start = (ushort)(data << 8);
                break;
            case 1:
                start |= data;
                break;
            case 2:
                end = (ushort)(data << 8);
                break;
            case 3:
                end |= data;
                cursorX = windowX0;
                cursorY = windowY0;
                break;
            }
            paramIndex = (paramIndex + 1) % 4;
        }

        private void HandlePixelByte(byte data)
        {
            if(pixelHighByte == null)
            {
                pixelHighByte = data;
                return;
            }

            // Standard MSB-first RGB565, the wire format every ILI9341
            // datasheet documents -- this repo's own to565_push
            // (app/wio/src/walk_main.cxx) exists precisely to put the
            // *correct* bytes on the wire for this board's SPI/panel
            // quirks, so a textbook-standard receiver here reproduces what
            // a real screen shows, not what a naive R5G6B5 read would.
            var word = (ushort)((pixelHighByte.Value << 8) | data);
            pixelHighByte = null;

            var r5 = (word >> 11) & 0x1F;
            var g6 = (word >> 5) & 0x3F;
            var b5 = word & 0x1F;

            if(cursorX <= windowX1 && cursorY <= windowY1 && cursorX < width && cursorY < height)
            {
                framebuffer[cursorX, cursorY, 0] = (byte)((r5 * 255 + 15) / 31);
                framebuffer[cursorX, cursorY, 1] = (byte)((g6 * 255 + 31) / 63);
                framebuffer[cursorX, cursorY, 2] = (byte)((b5 * 255 + 15) / 31);
            }

            // RAMWR auto-increment: sweep the CASET/PASET window left to
            // right, top to bottom, exactly like real ILI9341 addressing --
            // this is what lets a single RAMWR command precede many pixels
            // across many separate SPI bursts (see FinishTransmission).
            cursorX++;
            if(cursorX > windowX1)
            {
                cursorX = windowX0;
                cursorY++;
                if(cursorY > windowY1)
                {
                    cursorY = windowY0;
                }
            }
        }

        private readonly int width;
        private readonly int height;
        private readonly byte[,,] framebuffer;

        private bool dcIsData;
        private byte? currentCommand;
        private int paramIndex;
        private byte? pixelHighByte;

        private ushort windowX0, windowX1, windowY0, windowY1;
        private ushort cursorX, cursorY;

        private const byte ColumnAddressSet = 0x2A;
        private const byte PageAddressSet = 0x2B;
        private const byte MemoryWrite = 0x2C;
    }
}
