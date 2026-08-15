# 48. Zundamon TTS on ONNX Runtime's WebGPU backend — scoped as upstream work, not implemented here

Date: 2026-08-15

## Status

Accepted

## Context

A request came in to run the Zundamon message narration (ADR 0046) on ONNX
Runtime's WebGPU execution provider instead of CPU. ADR 0046 already flagged
GPU acceleration as out of scope and hard-coded
`VOICEVOX_ACCELERATION_MODE_CPU`, but that note was written assuming CUDA/
DirectML — the only backends VOICEVOX CORE was known to support. WebGPU
specifically needed its own investigation, because this engine never talks
to ONNX Runtime directly: `src/voicevox_tts.cxx` only `dlopen()`s
**VOICEVOX CORE**, a separate Rust project (`VOICEVOX/voicevox_core`) that
owns the ONNX Runtime session internally end to end. Any execution-provider
choice has to be made — and be possible to make — inside VOICEVOX CORE, not
in this repo.

Tracing the dependency chain (VOICEVOX CORE → its `ort` crate binding →
upstream Microsoft ONNX Runtime → `VOICEVOX/onnxruntime-builder`, the
project that produces the `libvoicevox_onnxruntime.so` this repo's download
script fetches):

- **Upstream ONNX Runtime does have a native WebGPU execution provider.**
  It is not the browser-only JSEP backend that `onnxruntime-web` uses —
  it's a Dawn-based EP built into the regular C/C++ library via the
  `onnxruntime_USE_WEBGPU` CMake option
  (`cmake/onnxruntime_providers_webgpu.cmake`,
  `cmake/vcpkg-ports/dawn/`), targeting Vulkan on Linux and D3D12 on
  Windows. So "WebGPU on native ONNX Runtime" is a real, shipped feature,
  not something that only exists in a browser.
- **VOICEVOX CORE's `ort` crate dependency already carries the Rust
  bindings for it.** `Cargo.toml:71` pins
  `ort = { git = "https://github.com/pykeio/ort.git", rev = "94417081…" }`,
  and that revision's `src/ep/webgpu.rs` exposes a full
  `WebGPUExecutionProvider` wrapper (`DawnBackendType::Vulkan`/`D3D12`,
  `PreferredLayout`, `BufferCacheMode`, …) gated behind a `webgpu` Cargo
  feature. VOICEVOX CORE just never turns that feature on —
  `crates/voicevox_core/Cargo.toml:64` enables
  `features = ["std", "ndarray", "tracing", "api-17", "alternative-backend"]`
  and nothing more.
- **VOICEVOX CORE's own device model has no WebGPU concept anywhere.**
  `crates/voicevox_core/src/core/devices.rs`'s `GpuSpec` enum is `Cuda |
  Dml` only. `crates/voicevox_core/src/core/infer/runtimes/onnxruntime.rs`
  matches on it in exactly three places —
  `supported_devices()` (~line 250, tests `CPUExecutionProvider`/
  `CUDAExecutionProvider`/`DirectMLExecutionProvider` availability and
  returns a `cpu`/`cuda`/`dml`-shaped `SupportedDevices` struct with no
  fourth field), `test_gpu()` (~line 268, registers CUDA or DirectML onto a
  throwaway `SessionBuilder` to probe availability) and `new_session()`
  (~line 298, registers the EP for real onto the session that does
  inference) — and `synthesizer.rs:292/304-316` is where
  `AccelerationMode::Gpu`/`Auto` picks the first GPU that `test_gpus()`
  reports OK from `GpuSpec::defaults()`. None of that plumbing has a third
  arm.
- **`VOICEVOX/onnxruntime-builder` does not build the WebGPU EP.** Nothing
  in its release notes, this repo's own `download-voicevox-zundamon.bash`
  comments, or the VOICEVOX CORE GPU docs
  (`docs/guide/user/gpu.md`) mentions it — the project ships CPU and (via
  the separate `voicevox_additional_libraries` archive already noted as
  unfetched in ADR 0046) CUDA/DirectML builds only.

So the request is technically sound — WebGPU is a real ONNX Runtime
backend and the Rust bindings for it already sit one `Cargo.toml` feature
flag away inside VOICEVOX CORE's own dependency tree — but it cannot be
turned on from this repo. This repo has no ONNX Runtime session to
configure; it can only pass `VOICEVOX_ACCELERATION_MODE_{AUTO,CPU,GPU}` to
a prebuilt `libvoicevox_core.so`, and that library's GPU path physically
does not know WebGPU exists yet.

## Decision

**Do not attempt a local workaround** (there is no session-creation code in
this repo to patch — `VOICEVOX_ACCELERATION_MODE_GPU` already exists and
still would not route to WebGPU even if enabled, since `GpuSpec` has no
WebGPU variant to select). Instead, document the upstream patch surface so
it's actionable as a future contribution, in three parts:

1. **`VOICEVOX/onnxruntime-builder`**: add a WebGPU-enabled build variant
   (Linux Vulkan / Windows D3D12 via Dawn, `onnxruntime_USE_WEBGPU=ON`),
   published as a new release asset alongside the existing CPU/CUDA/
   DirectML ones. This is the only piece with no existing scaffolding —
   everything else below is enabling code paths that already partially
   exist.
2. **`VOICEVOX/voicevox_core`** (Rust): add `GpuSpec::WebGpu`
   (`devices.rs`); enable the `ort` crate's `webgpu` feature
   (`crates/voicevox_core/Cargo.toml:64`); register
   `ort::ep::webgpu::WebGPU::default()` alongside the CUDA/DirectML arms in
   `onnxruntime.rs`'s `supported_devices()`, `test_gpu()` and
   `new_session()`; add it to `GpuSpec::defaults()` so
   `AccelerationMode::Auto`/`Gpu` can pick it up; extend the C API
   (`voicevox_core_c_api`) only if WebGPU needs to be *selectable* rather
   than auto-detected — plausibly not, since `VoicevoxAccelerationMode`'s
   existing `GPU` value already means "best available GPU EP," so a
   correctly-built `libvoicevox_onnxruntime.so` would make WebGPU "just
   work" through the mode this repo already passes.
3. **This repo**: once (1) and (2) ship a release, update
   `scripts/download-voicevox-zundamon.bash` to fetch the WebGPU-enabled
   ONNX Runtime build, and change `init_opts.acceleration_mode` in
   `src/voicevox_tts.cxx:244` from `VOICEVOX_ACCELERATION_MODE_CPU` to
   `VOICEVOX_ACCELERATION_MODE_GPU` (or `AUTO`, to fail soft to CPU on
   machines without a WebGPU-capable driver) — no header changes needed
   beyond that, since `include/voicevox_core_capi.hxx`'s trimmed mirror
   already only needs the enum values it currently has.

This repo is not the right place to carry that patch: VOICEVOX CORE is a
third-party dependency consumed only via its published C API, and forking
it (rather than upstreaming) would mean maintaining a private ONNX
Runtime + VOICEVOX CORE build pipeline indefinitely, on top of a fork of
a Rust project this repo has no other Rust tooling for.

## Consequences

- **`--zundamon_tts` stays CPU-only for now**, unchanged from ADR 0046.
  Nothing in this decision touches shipped behavior.
- **The path to WebGPU is now a scoped, cross-repo task** rather than an
  open question: one release-pipeline change upstream
  (`onnxruntime-builder`), one small, well-precedented Rust patch upstream
  (`voicevox_core` — mirrors the existing CUDA/DirectML wiring almost
  line-for-line, since the `ort` crate already has the bindings), and a
  two-line change here once both land.
- **The realistic blocker is upstream review bandwidth and CI capacity,
  not code complexity.** VOICEVOX CORE's GPU support has a history of
  correctness issues on first landing (DirectML's abnormal-output reports
  in `VOICEVOX/voicevox_core#143`), so a WebGPU arm would need the same
  numerical scrutiny CUDA/DirectML got before being trusted for narration
  audio.
- **If VOICEVOX CORE never adds this**, the only other way to get
  WebGPU-backed synthesis would be replacing VOICEVOX CORE entirely with a
  different inference stack this engine drives directly (e.g. running
  ONNX Runtime with the WebGPU EP against a raw VOICEVOX-compatible model
  ourselves) — a materially larger change than anything in ADR 0046, and
  not something this ADR recommends pursuing speculatively.
