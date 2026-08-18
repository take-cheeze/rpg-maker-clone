// Hand-written stand-in for the config.h that pspsdk's own `./bootstrap &&
// ./configure` would normally autoconf-generate. Building the patched
// psp-fixup-imports (see psp-fixup-imports-jal-relocation-aware.patch and
// scripts/build_psp_fixup_imports.bash) needs *a* config.h to exist --
// tools/types.h includes it unconditionally, not guarded by HAVE_CONFIG_H --
// but grep across tools/psp-fixup-imports.c, tools/types.h, and everything
// else that file pulls in shows only these three HAVE_* macros are ever
// actually tested by a preprocessor conditional. Running the full pspsdk
// autotools bootstrap just to generate the other several dozen unused
// HAVE_*/PACKAGE_* defines a real ./configure run would produce isn't worth
// the extra CI dependencies (autoconf, automake) for three #defines.
#define HAVE_CONFIG_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
