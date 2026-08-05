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

#include <string>
#include <unordered_map>

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
  if (!chunk)
    LOG(WARNING) << "Audio: failed to load sample '" << path
                 << "': " << Mix_GetError();
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
// decoders treat 0 as "loop forever".
bool start_music(const std::string& what, int volume, int loops) {
  Mix_VolumeMusic(to_mix_volume(volume));
  if (Mix_PlayMusic(g_music, loops) < 0) {
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
  return true;
}

// Free and replace the current music with a freshly loaded stream, then play it
// (loops = -1 loops forever, 1 plays once). Returns false on load failure.
bool play_music(const std::string& path, int volume, int loops) {
  free_music();
  g_music = Mix_LoadMUS(path.c_str());
  if (!g_music) {
    LOG(WARNING) << "Audio: failed to load music '" << path
                 << "': " << Mix_GetError();
    return false;
  }
  return start_music(path, volume, loops);
}

// The same, from encoded bytes. The bytes are copied into g_music_bytes first:
// Mix_LoadMUS_RW streams from the RWops for the life of the music, so the
// buffer has to stay put and stay ours (the caller's may be a temporary).
bool play_music_mem(const std::string& name,
                    const void* data,
                    int size,
                    int volume,
                    int loops) {
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
  g_music = Mix_LoadMUS_RW(rw, 1);  // 1: SDL_mixer closes the RWops
  if (!g_music) {
    LOG(WARNING) << "Audio: failed to load archived music '" << name << "' ("
                 << size << " bytes): " << Mix_GetError();
    g_music_bytes.clear();
    return false;
  }
  return start_music(name, volume, loops);
}

// Replay the BGM, from wherever it came from. Used to resume after a music
// effect ends; an archived BGM has no path, only the bytes kept in g_bgm_bytes.
bool replay_bgm(void) {
  if (!g_bgm_bytes.empty())
    return play_music_mem(g_bgm_path, g_bgm_bytes.data(),
                          (int)g_bgm_bytes.size(), g_bgm_volume, -1);
  return play_music(g_bgm_path, g_bgm_volume, -1);
}

// -- BGM --------------------------------------------------------------------

void bgm_play(const char* path, int volume, int /*pitch*/) {
  g_me_active = false;
  g_bgm_valid = true;
  g_bgm_path = path;
  g_bgm_bytes.clear();  // a file now, not archived bytes
  g_bgm_volume = volume;
  play_music(g_bgm_path, volume, -1);
}

void bgm_play_mem(const char* name,
                  const void* data,
                  int size,
                  int volume,
                  int /*pitch*/) {
  g_me_active = false;
  g_bgm_valid = true;
  g_bgm_path = name;  // for diagnostics only; there is no file
  g_bgm_bytes.assign(static_cast<const char*>(data), static_cast<size_t>(size));
  g_bgm_volume = volume;
  if (!play_music_mem(g_bgm_path, g_bgm_bytes.data(), (int)g_bgm_bytes.size(),
                      volume, -1))
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
  g_me_active = true;
  if (!play_music(path, volume, 1))
    g_me_active = false;  // load failed: nothing to wait for.
}

void me_play_mem(const char* name,
                 const void* data,
                 int size,
                 int volume,
                 int /*pitch*/) {
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
  // Resume the BGM once a music effect has finished (or faded out).
  if (g_me_active && !Mix_PlayingMusic()) {
    g_me_active = false;
    if (g_bgm_valid)
      replay_bgm();
  }
}

const RgssAudioBackend kBackend = {
    bgm_play, bgm_stop, bgm_fade,     bgm_pos,      bgs_play,    bgs_stop,
    bgs_fade, bgs_pos,  me_play,      me_stop,      me_fade,     se_play,
    se_stop,  update,   bgm_play_mem, bgs_play_mem, me_play_mem, se_play_mem,
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
  g_opened = false;
}
