- The optcarrot probe summary has a **Hot-path fps** column: each runtime also
  makes a short run (`OPTCARROT_WARMUP_FRAMES`, default a tenth of the frames),
  and the frame rate between the two runs leaves out startup and JIT warmup.
