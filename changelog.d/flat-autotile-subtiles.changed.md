- The autotile subtile tables are flat Integer Arrays instead of nested ones,
  which saves about 490 heap objects on the closed and Wio builds. bc2cpp now
  compiles class bodies that hold literals longer than mrbc's register window,
  and a VM-free build stops at generation when it cannot compile a class body
  instead of booting without it.
