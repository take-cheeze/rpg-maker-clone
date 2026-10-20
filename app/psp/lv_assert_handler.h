// LV_ASSERT_HANDLER_INCLUDE target for app/psp/lv_conf.h.
//
// Deliberately NOT psp.hxx: this header is pulled into LVGL's own plain-C
// translation units (lv_conf.h is included from both C and C++ code), and
// psp.hxx uses C++-only syntax (constexpr). This file has to compile as
// either language, so it is nothing but a bare function declaration.

#ifndef PSP_LV_ASSERT_HANDLER_H
#define PSP_LV_ASSERT_HANDLER_H

#ifdef __cplusplus
extern "C" {
#endif

// Called in place of LVGL's own default LV_ASSERT_HANDLER (an unconditional
// `while(1);`) whenever LV_USE_ASSERT_MALLOC/LV_USE_ASSERT_NULL trips --
// chiefly lv_malloc() returning NULL because LV_MEM_SIZE's pool is exhausted.
// The stock handler halts silently: nothing distinguishes that failure from
// any other hang, which is exactly the class of bug this port spent real
// effort chasing (ADR 0047). This one writes a libc-free marker via
// sceIoWrite -- the same reasoning app/psp/main.cxx's StrBuf/psp_write
// already use, since pspsdk's sysclib_snprintf is not to be trusted here
// either -- so the log names the failure before it halts. Defined in
// mruby-rgss/src/psp.cxx, which already owns the PSP LVGL HAL and links into
// both the CMake EBOOT and the psp mruby cross-build.
void psp_lvgl_assert_halt(void);

#ifdef __cplusplus
}
#endif

#endif  // PSP_LV_ASSERT_HANDLER_H
