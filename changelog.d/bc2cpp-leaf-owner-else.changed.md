- **bc2cpp**: a closed-build send guarded by an exact-class test on a class with no subclass no longer keeps a by-name
  owner call as its fallback; the fallback raises NoMethodError directly (27 sites, mostly RPG2k::Scene::Map).
