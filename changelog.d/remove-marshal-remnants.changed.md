- Internal: the code paths the removed Marshal save left behind are gone
  (`Game::State#to_h`/`.load` and the sub-serializers only they used). The `.lsd`
  save and load paths are unchanged.
