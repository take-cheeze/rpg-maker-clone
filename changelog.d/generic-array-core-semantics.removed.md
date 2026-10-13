- Remove application-named array capacity-retention and super-dispatch exceptions
  from bc2cpp. Array clear and concat retain their generic core-derived paths,
  including upstream memory sharing, frozen checks and override fallbacks.
