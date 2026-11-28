// MAPPED_LCF: LCF::Database and LCF::MapUnit read a game file in place where
// the platform already holds its bytes (a game image in flash), instead of
// into heap Strings (mruby-lcf/src/lcf.cxx, LCF.mapped_file).
#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The bytes of the file at `path`, or null to read the file. They must stay
// readable and unchanged while anything points into them, which nothing
// tracks: for the rest of the run, unless the platform asks
// lcf_mapped_in_use before it reuses them.
typedef const void* (*lcf_file_map_fn)(const char* path, size_t* len);
void lcf_set_file_map(lcf_file_map_fn map);

// FILE_CACHE: a platform that reuses mapped bytes asks first whether anything
// still points into them: used[i] for each of the n ranges the VM still holds
// a String, an LCF::ShortArray or a symbol name in, after a full GC.
typedef struct {
  const void* p;
  size_t len;
} lcf_mapped_range;
struct mrb_state;
void lcf_mapped_in_use(struct mrb_state* M,
                       const lcf_mapped_range* ranges,
                       size_t n,
                       bool* used);

#ifdef __cplusplus
}
#endif
