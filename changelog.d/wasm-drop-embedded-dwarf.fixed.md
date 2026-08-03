- The wasm build no longer embeds full DWARF debug info in `index.wasm` (dropped
  the link-time `-g3`), which had grown the binary past Cloudflare Pages' 25 MiB
  per-file limit and broke the `preview-cloudflare` deploy. `-gsource-map` is
  kept, so `index.wasm.map` still symbolicates wasm stack traces to file:line —
  the embedded DWARF only fed an interactive debugger, not the printed traces.
