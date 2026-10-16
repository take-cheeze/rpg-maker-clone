- The RGSS self-probes (`tilemap_above_layer_probe`, `audio_probe`) no longer
  read or write instance variables by reflection, so the closed-world lint
  baseline loses its three `Dynamic/IvarReflection` entries.
