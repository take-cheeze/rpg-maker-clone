- **bc2cpp** now inlines clean `Hash#each_value` blocks whose receivers are
  proven to be exact Hashes, removing their RProc and dynamic block dispatch from
  hot-only output. The real RPG2K source shrinks by 1,363 bytes and two hot
  fallback regions disappear; unknown receivers retain the existing fallback.
