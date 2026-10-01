- **bc2cpp ranks its remaining dynamic sites by executed count.** Setting
  `BC2CPP_SITE_PROFILE=DIR` counts every `bc2cpp_send` and `mrb_funcall*` site
  in the built binary, and `scripts/bc2cpp_dynamic_site_census.rb --rank` prints
  the hottest sites with the reason each stayed dynamic and the proof that would
  remove it. Off by default; the generated C++ is unchanged when it is unset.
  Covered by `scripts/bc2cpp_site_profile_check.rb`; see
  `docs/adr/0298-bc2cpp-executed-site-profile.md`.
