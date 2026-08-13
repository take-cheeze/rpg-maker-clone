- **Enemy troop members now render front-to-back in the correct order.**
  yado.tk: the lower-numbered (first-added) member should render closer to
  the camera. `Scene::Map`'s battler sprite z-values were inverted — the
  last-added member appeared on top instead of the first — since the
  native renderer draws the highest-z sprite on top but the code assigned
  z in ascending add-order. Fixed via a shared `#battler_z` helper used by
  every place a battler sprite's depth is set (initial build, mid-fight
  graphic change, Show Hidden Monster).
