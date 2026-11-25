// QSPI_XIP: the state of the external flash window the cold code runs from
// (wio_qspi_xip.cxx). WIO_QSPI_XIP is 1 when app/wio/qspi_xip.py links with
// app/wio/qspi_xip.ld; WIO_QSPI_XIP=0 builds leave everything internal.
#pragma once

#ifndef WIO_QSPI_XIP
#define WIO_QSPI_XIP 0
#endif

#define WIO_QSPI_XIP_OK 0
#define WIO_QSPI_XIP_UNCHECKED 1
#define WIO_QSPI_XIP_NO_IMAGE 2
#define WIO_QSPI_XIP_STALE 3
#define WIO_QSPI_XIP_CORRUPT 4

#ifdef __cplusplus
extern "C" {
#endif

#if WIO_QSPI_XIP
int wio_qspi_xip_status(void);
const char* wio_qspi_xip_status_text(void);
// Returns only when the image is this firmware's: otherwise shows why on the
// LCD and the serial port, blinking the user LED, forever. setup() calls it
// before anything that may reach QSPI code.
void wio_qspi_xip_require(void);
#else
static inline void wio_qspi_xip_require(void) {}
#endif

#ifdef __cplusplus
}
#endif
