- **CI: fix the intermittent `exe_open` failure.** The "MV real-game play smoke
  test" in `.github/workflows/build.yml` was still launching `xvfb-run -a` while
  its siblings use reserved fixed display numbers. In the shared `parallel`
  group its non-atomic display probe could grab `exe_open`'s reserved `:99`,
  killing that Xvfb out from under the client ("XIO: fatal IO error") and
  failing the required `build` check at random. Give it its own reserved
  `--server-num=105` so no MV smoke can collide with `exe_open`.
