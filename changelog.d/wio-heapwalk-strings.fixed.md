- **Wio heap snapshots no longer count their own garbage.** A snapshot read
  every class's name through `mrb_class_name`, which copies it into a new
  String, so the heap it saved held one such copy per nested class and probe:
  about 600 extra Strings and 9 KB at the title's peak.
  `scripts/wio/heapwalk_report.rb --strings` adds a census of the live
  Strings by kind, holder, buffer site and duplicated bytes.
