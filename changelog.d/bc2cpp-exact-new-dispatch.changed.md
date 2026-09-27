- bc2cpp now removes runtime class checks and dynamic dispatch fallbacks for
  fresh instances whose class constant and standard constructor lookup are
  proven stable in closed-world builds.
