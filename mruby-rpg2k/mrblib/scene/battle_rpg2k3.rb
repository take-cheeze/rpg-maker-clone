module RPG2k3
  module Scene
    # RPG2003 battle scene. It subclasses the RPG2000 Scene::Battle so it
    # inherits the entire command / target-cursor / animation machinery --
    # which is already edition-agnostic, since the RPG2003 battle commands are
    # ported (ADR 0048) and the database decode is id-driven. Only the *timing*
    # layer is overridden, keeping the 2000 battle completely untouched.
    #
    # For a gauge (active-time) presentation (battle_type 2) #update advances
    # every combatant's gauge each frame; the next step (ADR 0054) replaces the
    # 2000 sequential round order with gauge-readiness-driven actor selection.
    # The traditional (0) and alternative (1) presentations run the inherited
    # turn-based machine unchanged.
    class Battle < RPG2k::Scene::Battle
      # Advance the active-time gauge every frame for a gauge battle, then run
      # the inherited update (enemy flashes / phase dispatch / ...). A
      # turn-based or alternative battle leaves the gauge at 0, so
      # Game::Battle#advance_gauges is a no-op there and 2000 behaviour is
      # preserved exactly.
      def update
        battle = @ui && @ui[:battle]
        battle.advance_gauges if battle && battle.battle_type == 2
        super
      end
    end
  end
end
