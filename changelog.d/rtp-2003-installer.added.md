- **An RPG Maker 2003 RTP installer**, `scripts/rtp_2003_install.bash`, joins
  the existing RPG2000 and XP ones (`rtp_install.bash` / `rtp_xp_install.bash`)
  and now runs alongside them in CI's "Download RTP" step. It fetches the
  genuine, freely-redistributed `2003rtp.zip` from `cdn.tkool.jp` and installs
  it under wine with its own response file (`scripts/setup_2003.iss`) — a
  separate InstallShield project from 2000's, not a copy of it, confirmed by
  extracting the installer's own compiled script (`data1.hdr`) and by a real
  install under wine: it registers under
  `Software\Enterbrain\RPG2003\RuntimePackagePath`, a different key with a
  different default install directory (`Program Files (x86)\Enterbrain\RPG2003`)
  than the shared `Software\ASCII\RPG2000` key 2000 and XP use, so both editions'
  RTPs can be installed side by side in the same `WINEPREFIX` without
  conflict. `src/main.cxx`'s `rtp_path()` does not yet read the new key — see
  its own comment — so a 2003 project whose only installed RTP is this one
  still needs that follow-up to be found by the engine. RPG Maker VX and VX
  Ace get their own installers too — see the VX/VX Ace changelog entry; MV and
  MZ still have no equivalent, since their bundled runtime assets were never
  hosted as a free download the way 2000/2003/XP/VX/VX Ace's were (confirmed
  against `cdn.tkool.jp`'s own naming pattern).
