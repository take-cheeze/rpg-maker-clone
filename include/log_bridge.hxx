#pragma once

// Install the hook (see terminal.hxx's "Stderr log bridge" section) that
// routes every buffered $stderr line into ng-log via LOG(WARNING).  Call this
// once, after nglog::InitializeLogging, before the mruby interpreter runs any
// Ruby code.  Lives in the executable rather than the mruby-rgss gem so the
// gem keeps no compile-time dependency on ng-log.
void log_bridge_install();
