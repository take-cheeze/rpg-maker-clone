# Tests for the audio bridge (milestone M5): MV's AudioManager overridden to
# enqueue plain-text ops, which Ruby drains and maps onto RGSS::Audio.

assert 'MV parses audio ops into RGSS::Audio call specs' do
  # *_play ops prepend the maker's audio/<kind>/ folder and carry volume/pitch.
  assert_equal [:bgm_play, "audio/bgm/Theme1", 90.0, 100.0],
               MV.parse_audio_op("bgm_play\tTheme1\t90\t100")
  assert_equal [:se_play, "audio/se/Cursor1", 80.0, 120.0],
               MV.parse_audio_op("se_play\tCursor1\t80\t120")
  assert_equal [:me_play, "audio/me/Victory1", 100.0, 100.0],
               MV.parse_audio_op("me_play\tVictory1\t100\t100")
  # Stops and all_stop.
  assert_equal [:bgm_stop], MV.parse_audio_op("bgm_stop")
  assert_equal [:all_stop], MV.parse_audio_op("all_stop")
  # Fades convert seconds -> milliseconds for RGSS.
  assert_equal [:bgm_fade, 2000], MV.parse_audio_op("bgm_fade\t2")
  # Unknown ops are ignored.
  assert_nil MV.parse_audio_op("nonsense\tfoo")
end

assert 'MV audio bridge overrides AudioManager to enqueue and drain ops' do
  # Minimal AudioManager stand-in; the bridge replaces its methods.
  MV::JS.eval("globalThis.AudioManager = {};")
  begin
    MV::JS.eval(MV::AUDIO_BRIDGE_JS)
    # Nothing queued yet.
    assert_equal "", MV::JS.eval("__mv_drainAudio()")
    # A BGM play enqueues one op and records _currentBgm (for saveBgm).
    MV::JS.eval("AudioManager.playBgm({ name: 'Theme1', volume: 90, pitch: 100, pan: 0 });")
    assert_equal "Theme1", MV::JS.eval("AudioManager._currentBgm.name")
    assert_equal "bgm_play\tTheme1\t90\t100", MV::JS.eval("__mv_drainAudio()")
    # Draining clears the queue.
    assert_equal "", MV::JS.eval("__mv_drainAudio()")
    # An SE with no name is skipped; a named one is enqueued.
    MV::JS.eval("AudioManager.playSe({ name: '', volume: 90, pitch: 100 }); " \
                "AudioManager.playSe({ name: 'Ok', volume: 90, pitch: 100 });")
    assert_equal "se_play\tOk\t90\t100", MV::JS.eval("__mv_drainAudio()")
    # stopBgm clears _currentBgm and enqueues a stop.
    MV::JS.eval("AudioManager.stopBgm();")
    assert_nil MV::JS.eval("AudioManager._currentBgm")
    assert_equal "bgm_stop", MV::JS.eval("__mv_drainAudio()")
  ensure
    MV::JS.eval("delete globalThis.AudioManager; delete globalThis.__mv_drainAudio; " \
                "delete globalThis.__mv_audioQueue;")
  end
end
