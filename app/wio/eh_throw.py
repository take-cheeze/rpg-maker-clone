# EH_THROW: libstdc++_nano's eh_throw.o (what --specs=nano.specs links) has no unwind tables and its __cxa_throw does
# not save the registers it clobbers, so no throw can leave __cxa_throw: every Ruby raise (a C++ throw, mruby's
# MRB_USE_CXX_EXCEPTION) ends in std::terminate. The full libsupc++'s eh_throw.o is the same source with unwind tables;
# linked as an object, it takes the place of the nano member. WIO_NANO_EH_THROW=1 keeps the nano one.
import os
import subprocess

Import("env")  # noqa: F821

if os.environ.get("WIO_NANO_EH_THROW") != "1":
    bin_dir = os.path.join(env.PioPlatform().get_package_dir("toolchain-gccarmnoneeabi"), "bin")  # noqa: F821
    # The firmware's multilib (board cpu, hard float as the framework builds it).
    multilib = ["-mcpu=cortex-m4", "-mthumb", "-mfloat-abi=hard", "-mfpu=fpv4-sp-d16"]
    lib = subprocess.check_output([os.path.join(bin_dir, "arm-none-eabi-g++")] + multilib +
                                  ["-print-file-name=libsupc++.a"], text=True).strip()
    if not os.path.isfile(lib):
        raise SystemExit("eh_throw: %s not found" % lib)
    build = env.subst("$BUILD_DIR")  # noqa: F821
    os.makedirs(build, exist_ok=True)
    subprocess.check_call([os.path.join(bin_dir, "arm-none-eabi-ar"), "x", lib, "eh_throw.o"], cwd=build)
    env.Append(LINKFLAGS=[os.path.join(build, "eh_throw.o")])  # noqa: F821
