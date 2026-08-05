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

// Loaded SE / BGS samples, keyed by path so repeated plays don't re-decode.
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

  LOG(WARNING) << "Audio: no TiMidity configuration found; MIDI music will "
                  "load but play silence. Set TIMIDITY_CFG to a patch set, or "
                  "install assets/timidity next to the executable.";
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

// Free and replace the current music with a freshly loaded stream, then play it
// (loops = -1 loops forever, 1 plays once). Returns false on load failure.
// Note: for music, 1 (not 0) is the portable "play once" value — some decoders
// treat 0 as "loop forever".
bool play_music(const std::string& path, int volume, int loops) {
  if (g_music) {
    Mix_HaltMusic();
    Mix_FreeMusic(g_music);
    g_music = nullptr;
  }
  g_music = Mix_LoadMUS(path.c_str());
  if (!g_music) {
    LOG(WARNING) << "Audio: failed to load music '" << path
                 << "': " << Mix_GetError();
    return false;
  }
  Mix_VolumeMusic(to_mix_volume(volume));
  if (Mix_PlayMusic(g_music, loops) < 0) {
    LOG(WARNING) << "Audio: failed to play music '" << path
                 << "': " << Mix_GetError();
    return false;
  }
  return true;
}

// -- BGM --------------------------------------------------------------------

void bgm_play(const char* path, int volume, int /*pitch*/) {
  g_me_active = false;
  g_bgm_valid = true;
  g_bgm_path = path;
  g_bgm_volume = volume;
  play_music(g_bgm_path, volume, -1);
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

int bgm_pos(void) {
#if defined(SDL_MIXER_VERSION_ATLEAST) && SDL_MIXER_VERSION_ATLEAST(2, 6, 0)
  if (g_music && !g_me_active) {
    double sec = Mix_GetMusicPosition(g_music);
    if (sec >= 0.0)
      return (int)(sec * 1000.0);
  }
#endif
  return 0;
}

// -- BGS --------------------------------------------------------------------

void bgs_play(const char* path, int volume, int /*pitch*/) {
  Mix_Chunk* chunk = load_chunk(path);
  if (!chunk)
    return;
  Mix_HaltChannel(kBgsChannel);
  Mix_Volume(kBgsChannel, to_mix_volume(volume));
  Mix_PlayChannel(kBgsChannel, chunk, -1);
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
  g_me_active = true;
  if (!play_music(path, volume, 1))
    g_me_active = false;  // load failed: nothing to wait for.
}

void me_stop(void) {
  if (!g_me_active)
    return;
  g_me_active = false;
  Mix_HaltMusic();
  if (g_bgm_valid)
    play_music(g_bgm_path, g_bgm_volume, -1);
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

void se_play(const char* path, int volume, int /*pitch*/) {
  Mix_Chunk* chunk = load_chunk(path);
  if (!chunk)
    return;
  int ch = Mix_PlayChannel(-1, chunk, 0);
  if (ch >= 0)
    Mix_Volume(ch, to_mix_volume(volume));
}

void se_stop(void) {
  // Halt every SE channel but leave the reserved BGS channel playing.
  int n = Mix_AllocateChannels(-1);
  for (int ch = kReservedChannels; ch < n; ++ch)
    Mix_HaltChannel(ch);
}

// -- per-frame --------------------------------------------------------------

void update(void) {
  // Resume the BGM once a music effect has finished (or faded out).
  if (g_me_active && !Mix_PlayingMusic()) {
    g_me_active = false;
    if (g_bgm_valid)
      play_music(g_bgm_path, g_bgm_volume, -1);
  }
}

const RgssAudioBackend kBackend = {
    bgm_play, bgm_stop, bgm_fade, bgm_pos, bgs_play,
    bgs_stop, bgs_fade, bgs_pos,  me_play, me_stop,
    me_fade,  se_play,  se_stop,  update,  midi_available,
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
  Mix_HaltMusic();
  if (g_music) {
    Mix_FreeMusic(g_music);
    g_music = nullptr;
  }
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
