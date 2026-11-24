- **bc2cpp**: the Ruby emitter's annotation table (version 4) now records every `while`/`until` loop and
  every block-carrying send. The build stops on any record its own bytecode contradicts
  (`LOOP_RECORDS`). Nothing reads the records for code yet, so the generated C++ is unchanged.
