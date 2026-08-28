// SDL_mixer audio backend for the desktop / browser build.
//
// All SDL_mixer specifics live here, in the executable, which is the only place
// with SDL on its include/link path (the mruby-rgss gem is also built for the
// standalone `rake test` binary and must not depend on SDL). RGSS::Audio's
// native methods (mruby-rgss/src/audio.cxx) call through a plain function table
// (include/rgss_audio.hxx); rgss_audio_init() below fills that table with the
// functions here and installs it, so the gem stays SDL-free.
//
// Mapping of RPG Maker audio channels onto SDL_mixer:
//   * BGM  -> the single Mix_Music stream, looping.
//   * ME   -> the Mix_Music stream too; it interrupts the BGM, plays once, and
//             then the BGM is reloaded and resumed (see maybe_resume_bgm()).
//   * BGS  -> a reserved mixer channel (0) playing a looping sample.
//   * SE   -> one-shot samples on the remaining channels; several overlap.
//
// Volume is the RPG 0..100 scale mapped onto SDL's 0..MIX_MAX_VOLUME. Pitch is
// accepted for API compatibility but not applied: SDL_mixer has no tempo/pitch
// control for either music or samples.

#include <SDL2/SDL.h>
// SDL_mixer lives under include/SDL2 with the CMake-config layout but directly
// on the SDL2 include dir with the pkg-config layout (and the emscripten port);
// accept whichever the build provides.
#if defined(__has_include) && __has_include(<SDL2/SDL_mixer.h>)
#include <SDL2/SDL_mixer.h>
#else
#include <SDL_mixer.h>
#endif

#include <ng-log/logging.h>

#include <cctype>
#include <string>
#include <unordered_map>
#include <vector>

#include "profiler.hxx"
#include "rgss_audio.hxx"

namespace {

// Channel 0 is reserved for the looping BGS; SE plays on channels 1..N.
constexpr int kBgsChannel = 0;
constexpr int kReservedChannels = 1;
constexpr int kTotalChannels = 32;

bool g_opened = false;

// Music (BGM / ME) share the one Mix_Music stream.
Mix_Music* g_music = nullptr;  // currently loaded/playing music (BGM or ME)
bool g_bgm_valid = false;      // a BGM is set and should resume after an ME
std::string g_bgm_path;
int g_bgm_volume = 100;
bool g_me_active = false;  // an ME is playing over the (suspended) BGM
// The BGM's own playback position (see bgm_pos) at the instant an ME
// interrupted it, so replay_bgm can resume there instead of restarting the
// track -- captured once per ME (see me_play/me_play_mem), not on a second ME
// that replaces one already playing, which would otherwise read 0 (bgm_pos
// reports 0 while g_me_active) and lose the original resume point.
int g_bgm_resume_pos_ms = 0;
// The BGM's encoded bytes when it came out of an encrypted archive rather than
// a file (empty otherwise). update() replays the BGM after a music effect
// finishes, and there is no path to replay from in that case, so the bytes have
// to be kept for as long as the BGM is the one to return to.
std::string g_bgm_bytes;
// Backing store for the currently loaded Mix_Music when it was loaded from
// memory. Mix_LoadMUS_RW *streams* from the SDL_RWops, so both it and the bytes
// under it must outlive the music -- Mix_FreeMusic releases the RWops (loaded
// with freesrc=1) but knows nothing about this buffer. Replaced only where the
// music is freed.
std::string g_music_bytes;

// Playback position of the music stream, tracked from the clock rather than
// asked of the decoder. Mix_GetMusicPosition is not a cheap getter: on the MIDI
// decoder it costs *hundreds of milliseconds* a call, and the RPG2000 runtime
// polls the position every frame to answer the "BGM played once" branch, which
// dragged Nepheshel's opening (135 .mid tracks) from 60 frames a second to
// under two. The only consumer is that loop detection, which needs no more than
// a value that wraps when the track restarts -- so the start time plus the
// track's duration answers it for free. Zero duration (an unknown-length
// stream) reports position 0 throughout, exactly as a backend that cannot
// report a position does.
Uint64 g_music_start_ms = 0;
int g_music_duration_ms = 0;

// Loaded SE / BGS samples, keyed by path -- or, for archived audio, by the
// archive entry name -- so repeated plays don't re-decode.
std::unordered_map<std::string, Mix_Chunk*> g_chunks;

// Resolved TiMidity configuration, or empty when none was found (MIDI then
// loads but plays silence). Set once by init_midi_config().
std::string g_timidity_cfg;

bool file_exists(const std::string& path) {
  if (path.empty())
    return false;
  SDL_RWops* rw = SDL_RWFromFile(path.c_str(), "rb");
  if (!rw)
    return false;
  SDL_RWclose(rw);
  return true;
}

bool has_midi_extension(const std::string& path) {
  std::string ext;
  size_t dot = path.find_last_of('.');
  if (dot == std::string::npos)
    return false;
  for (size_t i = dot; i < path.size(); ++i)
    ext += (char)std::tolower((unsigned char)path[i]);
  return ext == ".mid" || ext == ".midi";
}

// Point SDL_mixer's built-in TiMidity synthesiser at a patch set.
//
// MIDI carries note events but no audio, so the synth needs a config naming a
// GUS patch (.pat) per GM program; with none, a .mid loads fine and then plays
// silence. The engine bundles the FreePats set in assets/timidity, so the usual
// answer is the copy shipped next to the executable — but a user-supplied
// TIMIDITY_CFG always wins, and a system-wide set is used when we ship none.
//
// Must run before Mix_OpenAudio: SDL_mixer initialises the TiMidity codec while
// opening the device, and reads the config exactly once at that point.
void init_midi_config(void) {
  // An explicit TIMIDITY_CFG is the user's override; SDL_mixer already honours
  // it ahead of everything else (TIMIDITY_Open in src/codecs/music_timidity.c),
  // so record it and leave it alone.
  const char* from_env = SDL_getenv("TIMIDITY_CFG");
  if (from_env && *from_env) {
    g_timidity_cfg = from_env;
    LOG(INFO) << "Audio: MIDI instruments from TIMIDITY_CFG='" << g_timidity_cfg
              << "'";
    return;
  }

  std::vector<std::string> candidates;
  // Next to the executable, both in a build tree and in an installed prefix.
  if (char* base = SDL_GetBasePath()) {
    candidates.push_back(std::string(base) + "assets/timidity/timidity.cfg");
    candidates.push_back(std::string(base) +
                         "../share/rpg-maker-clone/timidity/timidity.cfg");
    SDL_free(base);
  }
#ifdef RGSS_TIMIDITY_CFG_SOURCE
  // Configure-time path into the source tree, so a build-directory run finds
  // the patches without copying 33 MB next to the binary.
  candidates.push_back(RGSS_TIMIDITY_CFG_SOURCE);
#endif
  // Emscripten preload mount (see WASM_MIDI_PATCHES in CMakeLists.txt).
  candidates.push_back("/timidity/timidity.cfg");
  // Fall back to a system-wide patch set; these mirror the paths SDL_mixer
  // itself compiles in, and cover distro timidity/freepats packages.
  candidates.push_back("/etc/timidity.cfg");
  candidates.push_back("/etc/timidity/timidity.cfg");
  candidates.push_back("/etc/timidity/freepats.cfg");
  candidates.push_back("/usr/share/timidity/timidity.cfg");

  for (const std::string& path : candidates) {
    if (!file_exists(path))
      continue;
    g_timidity_cfg = path;
#if defined(SDL_MIXER_VERSION_ATLEAST) && SDL_MIXER_VERSION_ATLEAST(2, 6, 0)
    Mix_SetTimidityCfg(g_timidity_cfg.c_str());
#endif
    // Also export it: SDL_mixer before 2.6 has no setter, and the env var is
    // read by every 2.x. Do not overwrite — an existing value was handled above
    // and must keep winning.
    SDL_setenv("TIMIDITY_CFG", g_timidity_cfg.c_str(), 0);
    LOG(INFO) << "Audio: MIDI instruments from '" << g_timidity_cfg << "'";
    return;
  }

#ifdef __EMSCRIPTEN__
  // The page's advice is different: there is no executable to install next to
  // and no environment to set, only the build flag that packages the patches.
  LOG(WARNING) << "Audio: this page carries no MIDI patch set, so .mid BGM/ME "
                  "will not play. Rebuild it after running "
                  "scripts/download-freepats.bash (or with "
                  "-DWASM_MIDI_PATCHES=ON).";
#else
  LOG(WARNING) << "Audio: no TiMidity configuration found; MIDI music will "
                  "load but play silence. Set TIMIDITY_CFG to a patch set, or "
                  "install assets/timidity next to the executable.";
#endif
}

int midi_available(void) {
  return g_timidity_cfg.empty() ? 0 : 1;
}

int to_mix_volume(int rpg_volume) {
  if (rpg_volume < 0)
    rpg_volume = 0;
  if (rpg_volume > 100)
    rpg_volume = 100;
  return rpg_volume * MIX_MAX_VOLUME / 100;
}

// Load a sample, caching it. Returns null (and logs once) on failure.
Mix_Chunk* load_chunk(const std::string& path) {
  auto it = g_chunks.find(path);
  if (it != g_chunks.end())
    return it->second;
  // Only the cache *miss* is timed: the hit above is the common per-frame case
  // and costs a hash lookup, while this decodes the whole sample on the calling
  // (game-loop) thread. Keeping them apart is what makes the section's `n`
  // count actual decodes -- see the audio-threading note in docs/profiling.md.
  ProfilerScope _scope("audio.sample_load");
  Mix_Chunk* chunk = Mix_LoadWAV(path.c_str());
  if (!chunk && has_midi_extension(path)) {
    // SE/BGS play as mixer samples, and SDL_mixer only synthesises MIDI on the
    // single music stream — so a MIDI SE cannot be decoded here however the
    // synth is configured. Say that outright rather than leaving a bare decode
    // error that looks like a missing patch set.
    LOG(WARNING) << "Audio: cannot play MIDI '" << path
                 << "' as an SE/BGS; MIDI is supported for BGM/ME only";
  } else if (!chunk) {
    LOG(WARNING) << "Audio: failed to load sample '" << path
                 << "': " << Mix_GetError();
  }
  // Cache even a null result so a missing file is not retried every frame.
  g_chunks[path] = chunk;
  return chunk;
}

// Load a sample from encoded bytes, caching it under `name` (an archive entry
// name, not a path). Mix_LoadWAV_RW decodes the whole sample up front, so the
// caller's bytes are not needed once this returns.
Mix_Chunk* load_chunk_mem(const std::string& name, const void* data, int size) {
  auto it = g_chunks.find(name);
  if (it != g_chunks.end())
    return it->second;
  ProfilerScope _scope("audio.sample_load");
  Mix_Chunk* chunk = nullptr;
  SDL_RWops* rw = SDL_RWFromConstMem(data, size);
  if (rw) {
    chunk = Mix_LoadWAV_RW(rw, 1);  // 1: SDL_mixer closes the RWops
    if (!chunk)
      LOG(WARNING) << "Audio: failed to decode archived sample '" << name
                   << "' (" << size << " bytes): " << Mix_GetError();
  } else {
    LOG(WARNING) << "Audio: SDL_RWFromConstMem failed for '" << name
                 << "': " << SDL_GetError();
  }
  // Cache even a null result so an undecodable entry is not retried every
  // frame.
  g_chunks[name] = chunk;
  return chunk;
}

// Free the current music stream and the buffer it was streaming from.
void free_music(void) {
  if (g_music) {
    Mix_HaltMusic();
    Mix_FreeMusic(g_music);
    g_music = nullptr;
  }
  g_music_bytes.clear();
}

// Start `music`, which has just been loaded. Shared tail of the two loaders
// below. Note: for music, 1 (not 0) is the portable "play once" value — some
// decoders treat 0 as "loop forever". pos_ms > 0 seeks to that position
// (RGSS3's Audio.bgm_play resume point) once playback has actually started; a
// decoder that cannot seek (or fails to) is left playing from the beginning
// rather than treated as a load failure — the track is still audible, just not
// resumed. fadein_ms > 0 (RPG2000's own Play BGM fade-in, cycle #202) ramps
// the volume up from silence to `volume` over that many milliseconds via
// Mix_FadeInMusic instead of jumping straight there via Mix_PlayMusic; 0 (the
// default, and every caller here before this cycle) is the original instant
// start.
bool start_music(const std::string& what, int volume, int loops, int pos_ms,
                 int fadein_ms = 0) {
  Mix_VolumeMusic(to_mix_volume(volume));
  const int rc = fadein_ms > 0 ? Mix_FadeInMusic(g_music, loops, fadein_ms)
                                : Mix_PlayMusic(g_music, loops);
  if (rc < 0) {
    LOG(WARNING) << "Audio: failed to play music '" << what
                 << "': " << Mix_GetError();
    return false;
  }
  // Start the clock this stream's position is read off (see g_music_start_ms).
  // The duration is asked for once per track here, not once per frame.
  g_music_start_ms = SDL_GetTicks64();
  g_music_duration_ms = 0;
#if defined(SDL_MIXER_VERSION_ATLEAST) && SDL_MIXER_VERSION_ATLEAST(2, 6, 0)
  const double seconds = Mix_MusicDuration(g_music);
  if (seconds > 0.0)
    g_music_duration_ms = (int)(seconds * 1000.0);
#endif
  if (pos_ms > 0) {
    // One-time seek at play start, not a per-frame poll -- unlike
    // Mix_GetMusicPosition (see g_music_start_ms's comment), this is not on any
    // hot path, so MIDI's cost there does not apply here.
    if (Mix_SetMusicPosition(pos_ms / 1000.0) == 0) {
      // Back-date the clock so bgm_pos() (elapsed since g_music_start_ms)
      // reports the seeked position immediately, not 0.
      g_music_start_ms -= (Uint64)pos_ms;
    } else {
      LOG(WARNING) << "Audio: could not seek music '" << what << "' to "
                   << pos_ms
                   << "ms, playing from the beginning: " << Mix_GetError();
    }
  }
  return true;
}

// Explain a music load that failed. A .mid with no patch set resolved does not
// fail for a reason the caller can read off SDL_mixer's message -- TiMidity
// reports the missing config file, not that this build shipped without one --
// so name the actual cause rather than passing the decoder's wording through.
// `size` is the archived entry's byte count, or -1 when the music came from a
// file (whose size adds nothing a path does not already say).
void log_music_load_failure(const std::string& what, int size = -1) {
  std::string origin = "'" + what + "'";
  if (size >= 0)
    origin = "archived " + origin + " (" + std::to_string(size) + " bytes)";
  if (has_midi_extension(what) && g_timidity_cfg.empty()) {
    LOG(WARNING) << "Audio: cannot play MIDI " << origin
                 << ": no patch set was found, so nothing can synthesise it "
                    "(see the startup warning). SDL_mixer said: "
                 << Mix_GetError();
    return;
  }
  LOG(WARNING) << "Audio: failed to load music " << origin << ": "
               << Mix_GetError();
}

// Free and replace the current music with a freshly loaded stream, then play it
// (loops = -1 loops forever, 1 plays once). Returns false on load failure.
// pos_ms defaults to 0 (play from the beginning) for the ME/replay callers
// below, which never seek; bgm_play (the one caller a resume position reaches)
// passes the real value through. fadein_ms likewise defaults to 0 (instant
// start) for every caller but bgm_play/bgm_play_mem -- see start_music's own
// doc comment.
bool play_music(const std::string& path,
                int volume,
                int loops,
                int pos_ms = 0,
                int fadein_ms = 0) {
  free_music();
  {
    // The music stream is opened on the game-loop thread. For MIDI this is the
    // TiMidity synth spinning up over the patch set, which is the single most
    // expensive audio call in the engine -- the reason this section exists.
    ProfilerScope _scope("audio.music_load");
    g_music = Mix_LoadMUS(path.c_str());
  }
  if (!g_music) {
    log_music_load_failure(path);
    return false;
  }
  return start_music(path, volume, loops, pos_ms, fadein_ms);
}

// The same, from encoded bytes. The bytes are copied into g_music_bytes first:
// Mix_LoadMUS_RW streams from the RWops for the life of the music, so the
// buffer has to stay put and stay ours (the caller's may be a temporary).
bool play_music_mem(const std::string& name,
                    const void* data,
                    int size,
                    int volume,
                    int loops,
                    int pos_ms = 0,
                    int fadein_ms = 0) {
  free_music();
  g_music_bytes.assign(static_cast<const char*>(data),
                       static_cast<size_t>(size));
  SDL_RWops* rw =
      SDL_RWFromConstMem(g_music_bytes.data(), (int)g_music_bytes.size());
  if (!rw) {
    LOG(WARNING) << "Audio: SDL_RWFromConstMem failed for '" << name
                 << "': " << SDL_GetError();
    g_music_bytes.clear();
    return false;
  }
  {
    ProfilerScope _scope("audio.music_load");
    g_music = Mix_LoadMUS_RW(rw, 1);  // 1: SDL_mixer closes the RWops
  }
  if (!g_music) {
    log_music_load_failure(name, size);
    g_music_bytes.clear();
    return false;
  }
  return start_music(name, volume, loops, pos_ms, fadein_ms);
}

// Replay the BGM, from wherever it came from. Used to resume after a music
// effect ends; an archived BGM has no path, only the bytes kept in g_bgm_bytes.
// Resumes at g_bgm_resume_pos_ms (see me_play/me_play_mem), matching real
// RGSS: a Music Effect interrupts the map BGM and it picks back up where it
// left off, not from the top.
bool replay_bgm(void) {
  const int pos_ms = g_bgm_resume_pos_ms;
  g_bgm_resume_pos_ms = 0;
  if (!g_bgm_bytes.empty())
    return play_music_mem(g_bgm_path, g_bgm_bytes.data(),
                          (int)g_bgm_bytes.size(), g_bgm_volume, -1, pos_ms);
  return play_music(g_bgm_path, g_bgm_volume, -1, pos_ms);
}

// -- BGM --------------------------------------------------------------------

void bgm_play(const char* path, int volume, int /*pitch*/, int pos_ms,
             int fadein_ms) {
  g_me_active = false;
  g_bgm_valid = true;
  g_bgm_path = path;
  g_bgm_bytes.clear();  // a file now, not archived bytes
  g_bgm_volume = volume;
  play_music(g_bgm_path, volume, -1, pos_ms, fadein_ms);
}

// Live volume change for whichever BGM is currently playing, with no restart:
// Mix_VolumeMusic applies to the already-loaded Mix_Music stream directly,
// unlike bgm_play's Mix_PlayMusic, which always begins the track from the top.
void bgm_volume(int volume) {
  g_bgm_volume = volume;
  Mix_VolumeMusic(to_mix_volume(volume));
}

// Live stereo-balance change for the BGM, with no restart -- the same shape
// as bgm_volume. SDL_mixer's Mix_SetPanning only works on Mix_Chunk mixer
// channels (0..N), never on the Mix_Music stream BGM/ME actually play
// through; the one documented way to reach the music at all is to register it
// as a postmix effect on MIX_CHANNEL_POST, which pans the *final* mixed
// output -- so this also pans BGS and SE, since there is no channel-scoped
// alternative for music (see the doc comment on Mix_SetPanning in
// SDL_mixer.h: "the panning will be done to the final mixed stream"). pan is
// RPG2000's own Play BGM balance scale: 0 full left, 50 centre, 100 full
// right. "True panning" per that same doc comment is Mix_SetPanning(chan,
// left, 255 - left), so right alone (0..255) is derived from pan and left is
// its complement.
void bgm_pan(int pan) {
  if (pan < 0)
    pan = 0;
  if (pan > 100)
    pan = 100;
  Uint8 right = (Uint8)(pan * 255 / 100);
  Uint8 left = (Uint8)(255 - right);
  Mix_SetPanning(MIX_CHANNEL_POST, left, right);
}

void bgm_play_mem(const char* name,
                  const void* data,
                  int size,
                  int volume,
                  int /*pitch*/,
                  int pos_ms,
                  int fadein_ms) {
  g_me_active = false;
  g_bgm_valid = true;
  g_bgm_path = name;  // for diagnostics only; there is no file
  g_bgm_bytes.assign(static_cast<const char*>(data), static_cast<size_t>(size));
  g_bgm_volume = volume;
  if (!play_music_mem(g_bgm_path, g_bgm_bytes.data(), (int)g_bgm_bytes.size(),
                      volume, -1, pos_ms, fadein_ms))
    g_bgm_bytes.clear();
}

void bgm_stop(void) {
  g_bgm_valid = false;
  g_me_active = false;
  Mix_HaltMusic();
}

void bgm_fade(int ms) {
  // Stop resuming this BGM; let the current stream fade out. It is freed on the
  // next play_music() or at shutdown.
  g_bgm_valid = false;
  g_me_active = false;
  if (ms <= 0)
    Mix_HaltMusic();
  else
    Mix_FadeOutMusic(ms);
}

// Milliseconds into the current BGM, wrapping every time the loop restarts.
// Read from the clock, not from the decoder -- see g_music_start_ms.
int bgm_pos(void) {
  // Mix_PlayingMusic() matters as much as g_music: halting the music does not
  // free the stream, and the position must not keep advancing for music that
  // is not playing -- a game that saves bgm_pos to resume the track later
  // (which is what RGSS2's `$game_system.bgm_pos` is for) would otherwise
  // write down a position for music that is stopped.
  if (!g_music || g_me_active || !g_bgm_valid || g_music_duration_ms <= 0 ||
      !Mix_PlayingMusic())
    return 0;
  const Uint64 elapsed = SDL_GetTicks64() - g_music_start_ms;
  return (int)(elapsed % (Uint64)g_music_duration_ms);
}

// -- BGS --------------------------------------------------------------------

void start_bgs(Mix_Chunk* chunk, int volume) {
  if (!chunk)
    return;
  Mix_HaltChannel(kBgsChannel);
  Mix_Volume(kBgsChannel, to_mix_volume(volume));
  Mix_PlayChannel(kBgsChannel, chunk, -1);
}

void bgs_play(const char* path, int volume, int /*pitch*/) {
  start_bgs(load_chunk(path), volume);
}

void bgs_play_mem(const char* name,
                  const void* data,
                  int size,
                  int volume,
                  int /*pitch*/) {
  start_bgs(load_chunk_mem(name, data, size), volume);
}

void bgs_stop(void) {
  Mix_HaltChannel(kBgsChannel);
}

void bgs_fade(int ms) {
  if (ms <= 0)
    Mix_HaltChannel(kBgsChannel);
  else
    Mix_FadeOutChannel(kBgsChannel, ms);
}

int bgs_pos(void) {
  return 0;  // Sample channels have no reported position.
}

// -- ME ---------------------------------------------------------------------

void me_play(const char* path, int volume, int /*pitch*/) {
  // Play once over the BGM; update() restores the BGM when the effect ends.
  // Capture the BGM's own position now, before g_me_active flips bgm_pos() to
  // 0 -- but only on the first ME of a run, not one that replaces another
  // already playing, which would capture 0 and lose the real resume point.
  if (!g_me_active)
    g_bgm_resume_pos_ms = bgm_pos();
  g_me_active = true;
  if (!play_music(path, volume, 1))
    g_me_active = false;  // load failed: nothing to wait for.
}

void me_play_mem(const char* name,
                 const void* data,
                 int size,
                 int volume,
                 int /*pitch*/) {
  if (!g_me_active)
    g_bgm_resume_pos_ms = bgm_pos();
  g_me_active = true;
  if (!play_music_mem(name, data, size, volume, 1))
    g_me_active = false;
}

void me_stop(void) {
  if (!g_me_active)
    return;
  g_me_active = false;
  Mix_HaltMusic();
  if (g_bgm_valid)
    replay_bgm();
}

void me_fade(int ms) {
  if (!g_me_active)
    return;
  if (ms <= 0) {
    me_stop();
    return;
  }
  // Keep g_me_active set: the per-frame update resumes the BGM once the fade
  // has silenced the music stream.
  Mix_FadeOutMusic(ms);
}

// -- SE ---------------------------------------------------------------------

void start_se(Mix_Chunk* chunk, int volume) {
  if (!chunk)
    return;
  int ch = Mix_PlayChannel(-1, chunk, 0);
  if (ch >= 0)
    Mix_Volume(ch, to_mix_volume(volume));
}

void se_play(const char* path, int volume, int /*pitch*/) {
  start_se(load_chunk(path), volume);
}

void se_play_mem(const char* name,
                 const void* data,
                 int size,
                 int volume,
                 int /*pitch*/) {
  start_se(load_chunk_mem(name, data, size), volume);
}

void se_stop(void) {
  // Halt every SE channel but leave the reserved BGS channel playing.
  int n = Mix_AllocateChannels(-1);
  for (int ch = kReservedChannels; ch < n; ++ch)
    Mix_HaltChannel(ch);
}

// -- per-frame --------------------------------------------------------------

void update(void) {
  ProfilerScope _scope("audio.update");
  // Resume the BGM once a music effect has finished (or faded out).
  if (g_me_active && !Mix_PlayingMusic()) {
    g_me_active = false;
    if (g_bgm_valid)
      replay_bgm();
  }
}

const RgssAudioBackend kBackend = {
    bgm_play,       bgm_volume,   bgm_pan,      bgm_stop,    bgm_fade,
    bgm_pos,        bgs_play,     bgs_stop,     bgs_fade,    bgs_pos,
    me_play,        me_stop,      me_fade,      se_play,     se_stop,
    update,         bgm_play_mem, bgs_play_mem, me_play_mem, se_play_mem,
    midi_available,
};

}  // namespace

// Open the audio device and install the SDL_mixer backend. Safe to call once,
// after SDL is available (SDL_mixer initialises the audio subsystem itself).
// On any failure the backend is left uninstalled, so every Audio call is a
// graceful no-op rather than a crash.
extern "C" void rgss_audio_init(void) {
  if (g_opened)
    return;
  if (SDL_InitSubSystem(SDL_INIT_AUDIO) < 0) {
    LOG(WARNING) << "Audio: SDL_InitSubSystem(AUDIO) failed: " << SDL_GetError()
                 << "; audio disabled";
    return;
  }
  // Best-effort codec init; unsupported formats simply stay unavailable.
  Mix_Init(MIX_INIT_OGG | MIX_INIT_MID | MIX_INIT_MP3 | MIX_INIT_FLAC);
  // Resolve the MIDI patch set before opening the device: SDL_mixer starts the
  // TiMidity codec from Mix_OpenAudio and reads its config only then.
  init_midi_config();
  if (Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 2048) < 0) {
    LOG(WARNING) << "Audio: Mix_OpenAudio failed: " << Mix_GetError()
                 << "; audio disabled";
    Mix_Quit();
    SDL_QuitSubSystem(SDL_INIT_AUDIO);
    return;
  }
  Mix_AllocateChannels(kTotalChannels);
  Mix_ReserveChannels(kReservedChannels);
  g_opened = true;
  rgss_audio_install_backend(&kBackend);
}

// Tear down the audio device and free every loaded sample/stream. Called on the
// native shutdown path (the emscripten main loop never returns).
extern "C" void rgss_audio_shutdown(void) {
  if (!g_opened)
    return;
  rgss_audio_install_backend(nullptr);
  Mix_HaltChannel(-1);
  // Frees the stream and, with it, the buffer an archived BGM streams from --
  // which must not be released before Mix_FreeMusic has run.
  free_music();
  g_bgm_bytes.clear();
  for (auto& kv : g_chunks) {
    if (kv.second)
      Mix_FreeChunk(kv.second);
  }
  g_chunks.clear();
  Mix_CloseAudio();
  Mix_Quit();
  SDL_QuitSubSystem(SDL_INIT_AUDIO);
  g_timidity_cfg.clear();
  g_opened = false;
}
