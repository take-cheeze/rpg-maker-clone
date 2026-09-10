- **Wio Terminal: assessed whether an "unexec"-style pre-baked mruby heap
  image (dump the fully-initialized VM, load it directly at boot instead
  of re-running gem-init) could close the RAM shortfall docs/adr/0136
  found -- real measurement says no, not by itself.** Walked the live
  object graph after a real `setup()` completion under Renode: 4,586 live
  objects, dominated by 2,485 method (`Proc`) wrappers and 220 classes'
  method tables (51,360 bytes on their own). The compiled bytecode itself
  costs zero RAM already (it's flash-resident `const` data from this
  project's own `mrbc`/cdump code generation) -- every Proc is just a
  20-byte wrapper pointing at it. Summing the categories measured with
  full confidence (RVALUE headers, method tables, closures, string/array
  buffers) alone already totals 173,344 bytes against a real usable heap
  of 163,360 -- a perfect, zero-waste image would still not fit. The real
  lever is reducing how much of RGSS/mruby-lcf/mruby-rpg2k gets defined at
  boot at all, not packing the same object count more efficiently. See
  docs/adr/0137.
