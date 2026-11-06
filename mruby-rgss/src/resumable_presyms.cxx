// Names the native Fiber continuation uses (NativeVM output,
// tools/bc2cpp/native_vm.rb). The presym list is built from the closed build's
// preprocessed sources before the generated code exists (stub generation), so
// these names are listed here, in an always-compiled source, and the list holds
// them whether or not the continuation is generated.
#include <mruby.h>
#include <mruby/presym.h>

extern "C" {
// Referenced by nothing; its only job is to put the presym names into the scan.
static const mrb_sym bc2cpp_continuation_presyms[] = {
    MRB_SYM(Bc2cppResumable),
    MRB_SYM(Frame),
    MRB_SYM(Fiber),
    MRB_SYM(take_initial),
    MRB_SYM(drive),
    MRB_SYM(value),
    MRB_SYM(block),
    MRB_SYM_Q(block_call),
    MRB_SYM(call),
    MRB_SYM(step),
    MRB_SYM(f),
    MRB_SYM(yield),
};
}
