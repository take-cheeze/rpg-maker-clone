- bc2cpp now lowers guarded exact, unshared Array `[]` sends with Fixnum slice
  lengths up to 10 to a direct copy in the Optcarrot probe build, while larger
  and shared slices retain mruby's Ruby dispatch and shared-storage path.
