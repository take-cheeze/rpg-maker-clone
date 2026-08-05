- CI logs only what the run is about. `actions/checkout` no longer prints
  fetch progress (`show-progress: false`) nor the post-job walk that unsets
  `includeIf` config for all 14 submodules (`persist-credentials: false`, on
  every job); `wget`/`unar`/`git clone` in the download and RTP scripts run
  quietly, so an archive no longer costs thousands of "downloading / extracting
  <file>" lines; wine's `fixme:` stub chatter is off during the RTP installs
  (`WINEDEBUG=fixme-all`, `err:`/`warn:` still print); the PSP smoke test writes
  PPSSPP's `--log` HLE trace to the uploaded `psp-smoke` artifact instead of the
  console, echoing the bring-up markers on success and the log tail on failure,
  and its `--help` dump is gone; `apt-get`, `pip` and the pspdev `docker pull`
  are quiet. The native MV/MZ smoke steps run through the new
  `scripts/quiet_alsa.bash`, which strips the "cannot find card '0'" flood a
  runner without a sound device produces — the same three patterns the boot
  checks already filtered — while preserving the engine's exit status and its
  `[MV-*]` markers.
