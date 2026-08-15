- Fixed `RGSS::ErrorReport.push` raising `NoMethodError` under plain CRuby.
  `scripts/error_report_check.rb` exercises `mruby-rgss/mrblib/error_report.rb`
  directly on the system Ruby (by design, so its ring-buffer bookkeeping is
  checked without an engine build); the new `RGSS.__log_bridge_write` forward
  to ng-log is now guarded with `respond_to?`, since that binding only exists
  inside the embedded mruby runtime.
