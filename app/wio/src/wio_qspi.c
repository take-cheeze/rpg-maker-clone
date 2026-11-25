// See wio_qspi.h. The command sequence is the SAMD51 QSPI's serial-memory mode:
// an instruction frame, the data phase as CPU accesses to the AHB window, then
// LASTXFER ends it (as Adafruit_SPIFlash's SAMD51 transport does).
#include "wio_qspi.h"

#include <sam.h>

#define CMD_WRITE_ENABLE 0x06
#define CMD_READ_SR1 0x05
#define CMD_READ_SR2 0x35
#define CMD_WRITE_SR2 0x31
#define CMD_SECTOR_ERASE 0x20
#define CMD_PAGE_PROGRAM 0x02
#define CMD_QUAD_OUTPUT_READ 0x6B
#define SR1_BUSY 0x01
#define SR2_QE 0x02

#ifndef VARIANT_QSPI_BAUD_DEFAULT
#define VARIANT_QSPI_BAUD_DEFAULT 5000000
#endif

// Peripheral function H (PIO_COM in variant.cpp) on one QSPI pin.
static void qspi_pin(int group, int pin) {
  PORT->Group[group].PINCFG[pin].reg |= PORT_PINCFG_PMUXEN;
  uint8_t pmux = PORT->Group[group].PMUX[pin >> 1].reg;
  pmux = (pin & 1) ? (uint8_t)((pmux & 0x0f) | (7u << 4))
                   : (uint8_t)((pmux & 0xf0) | 7u);
  PORT->Group[group].PMUX[pin >> 1].reg = pmux;
}

void wio_qspi_command(uint8_t cmd,
                      int32_t addr,
                      uint8_t* buf,
                      uint32_t len,
                      int write) {
  uint32_t frame = QSPI_INSTRFRAME_WIDTH_SINGLE_BIT_SPI |
                   QSPI_INSTRFRAME_ADDRLEN_24BITS | QSPI_INSTRFRAME_INSTREN;
  if (!write)
    frame |= QSPI_INSTRFRAME_TFRTYPE_READ;
  else if (addr >= 0)
    frame |= QSPI_INSTRFRAME_TFRTYPE_WRITEMEMORY;
  else
    frame |= QSPI_INSTRFRAME_TFRTYPE_WRITE;
  if (addr >= 0)
    frame |= QSPI_INSTRFRAME_ADDREN;
  if (buf && len)
    frame |= QSPI_INSTRFRAME_DATAEN;
  QSPI->INSTRCTRL.reg = QSPI_INSTRCTRL_INSTR(cmd);
  QSPI->INSTRADDR.reg = addr >= 0 ? (uint32_t)addr : 0;
  QSPI->INSTRFRAME.reg = frame;
  // The frame must be in place before the data phase's first access.
  (void)QSPI->INSTRFRAME.reg;
  volatile uint8_t* ahb =
      (volatile uint8_t*)(QSPI_AHB + (addr >= 0 ? (uint32_t)addr : 0));
  for (uint32_t i = 0; buf && i < len; i++) {
    if (write)
      ahb[i] = buf[i];
    else
      buf[i] = ahb[i];
  }
  __DSB();
  __ISB();
  QSPI->CTRLA.reg = QSPI_CTRLA_ENABLE | QSPI_CTRLA_LASTXFER;
  while (!(QSPI->INTFLAG.reg & QSPI_INTFLAG_INSTREND)) {
  }
  QSPI->INTFLAG.reg = QSPI_INTFLAG_INSTREND;
}

static uint8_t read_status(uint8_t cmd) {
  uint8_t v = 0;
  wio_qspi_command(cmd, -1, &v, 1, 0);
  return v;
}

static void wait_ready(void) {
  while (read_status(CMD_READ_SR1) & SR1_BUSY) {
  }
}

void wio_qspi_begin(void) {
  MCLK->APBCMASK.reg |= MCLK_APBCMASK_QSPI;
  MCLK->AHBMASK.reg |= MCLK_AHBMASK_QSPI;
  MCLK->AHBMASK.reg &= ~MCLK_AHBMASK_QSPI_2X;
  qspi_pin(0, 8);
  qspi_pin(0, 9);
  qspi_pin(0, 10);
  qspi_pin(0, 11);
  qspi_pin(1, 10);
  qspi_pin(1, 11);

  QSPI->CTRLA.reg = QSPI_CTRLA_SWRST;
  // SCK = CLK_QSPI_AHB (the CPU clock) / (BAUD + 1), rounded down to the
  // variant's rate.
  const uint32_t div = (F_CPU + VARIANT_QSPI_BAUD_DEFAULT - 1) /
                       VARIANT_QSPI_BAUD_DEFAULT;
  QSPI->BAUD.reg = QSPI_BAUD_BAUD(div ? div - 1 : 0);
  QSPI->CTRLB.reg = QSPI_CTRLB_MODE_MEMORY | QSPI_CTRLB_DATALEN_8BITS |
                    QSPI_CTRLB_CSMODE_LASTXFER;
  QSPI->CTRLA.reg = QSPI_CTRLA_ENABLE;
}

void wio_qspi_quad_enable(void) {
  uint8_t sr2 = read_status(CMD_READ_SR2);
  if (sr2 & SR2_QE)
    return;
  sr2 |= SR2_QE;
  wio_qspi_command(CMD_WRITE_ENABLE, -1, 0, 0, 0);
  wio_qspi_command(CMD_WRITE_SR2, -1, &sr2, 1, 1);
  wait_ready();
}

void wio_qspi_erase_sector(uint32_t addr) {
  wio_qspi_command(CMD_WRITE_ENABLE, -1, 0, 0, 0);
  wio_qspi_command(CMD_SECTOR_ERASE, (int32_t)addr, 0, 0, 0);
  wait_ready();
}

void wio_qspi_program_page(uint32_t addr, const uint8_t* data, uint32_t len) {
  wio_qspi_command(CMD_WRITE_ENABLE, -1, 0, 0, 0);
  wio_qspi_command(CMD_PAGE_PROGRAM, (int32_t)addr, (uint8_t*)data, len, 1);
  wait_ready();
}

void wio_qspi_enter_xip(void) {
  QSPI->INSTRCTRL.reg = QSPI_INSTRCTRL_INSTR(CMD_QUAD_OUTPUT_READ);
  // Eight dummy cycles are 0x6B's.
  QSPI->INSTRFRAME.reg =
      QSPI_INSTRFRAME_WIDTH_QUAD_OUTPUT | QSPI_INSTRFRAME_ADDRLEN_24BITS |
      QSPI_INSTRFRAME_TFRTYPE_READMEMORY | QSPI_INSTRFRAME_INSTREN |
      QSPI_INSTRFRAME_ADDREN | QSPI_INSTRFRAME_DATAEN |
      QSPI_INSTRFRAME_DUMMYLEN(8);
  (void)QSPI->INSTRFRAME.reg;
  __DSB();
  __ISB();
}

void wio_cmcc_enable(void) {
  CMCC->CTRL.reg = 0;
  while (CMCC->SR.reg & CMCC_SR_CSTS) {
  }
  CMCC->MAINT0.reg = CMCC_MAINT0_INVALL;
  CMCC->CTRL.reg = CMCC_CTRL_CEN;
}

uint32_t wio_crc32(uint32_t crc, const volatile uint8_t* p, uint32_t len) {
  // Four bits at a time: a 64-byte table instead of 1 KB of internal flash.
  static const uint32_t kNibble[16] = {
      0x00000000, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190, 0x6b6b51f4,
      0x4db26158, 0x5005713c, 0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c,
      0x9b64c2b0, 0x86d3d2d4, 0xa00ae278, 0xbdbdf21c};
  crc = ~crc;
  for (uint32_t i = 0; i < len; i++) {
    crc ^= p[i];
    crc = (crc >> 4) ^ kNibble[crc & 15];
    crc = (crc >> 4) ^ kNibble[crc & 15];
  }
  return ~crc;
}
