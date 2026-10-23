- **Type check candidates** name the IR exit behind each method's return: every
  `--emit-rbs-suggestions` method gets a one-line `# bc2cpp: return from FILE:LINE (...)`
  comment with the return's source, status and contract dependencies. The
  comments are documentation only and do not change the parsed signatures.
- **Type check report** ranks the IR queries left unknown by refusal reason, most
  frequent first, with the files each reason hits, so the next producer worth
  modeling is visible. The JSON output keeps its shape.
