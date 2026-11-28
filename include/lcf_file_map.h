// MAPPED_LCF: LCF::Database and LCF::MapUnit read a game file in place where
// the platform already holds its bytes (a game image in flash), instead of
// into heap Strings (mruby-lcf/src/lcf.cxx, LCF.mapped_file).
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The bytes of the file at `path`, or null to read the file. They must stay
// readable and unchanged for the rest of the run: Strings and LCF::ShortArray
// tables point into them with nothing that keeps them alive.
typedef const void* (*lcf_file_map_fn)(const char* path, size_t* len);
void lcf_set_file_map(lcf_file_map_fn map);

#ifdef __cplusplus
}
#endif
