- The optcarrot benchmark (`tools/optcarrot_probe/compiled_run.rb`) now compares against CRuby 4.0 with YJIT instead of
  the interpreter. `OPTCARROT_CRUBY` names another Ruby, and the runner aborts on one built without YJIT.
