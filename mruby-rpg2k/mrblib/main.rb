class Object
  include RGSS
end

module RGSS
  class Window
    attr_accessor :contents

    def initialize(x = 0, y = 0, width = 0, height = 0)
      @x = x
      @y = y
      @width = width
      @height = height
      @contents = nil
    end

    attr_accessor :x, :y, :width, :height
  end
end

class RPG2k
  WIDTH = 320
  HEIGHT = 240

  module Scene
    class Base
      def initialize parent
        @db = parent.db
        @map_tree = parent.map_tree
      end
      def update ; end

      attr_reader :db, :map_tree
    end

    class Title < Base
      def initialize parent
        super parent

        @title = Sprite.new
        @title.bitmap = Bitmap.new "Title/#{db.system.title}"

        @menu_items = [db.term.new_game, db.term.continue, db.term.shutdown]

        # Calculate window size based on menu items
        item_height = 24  # Height for each menu item
        window_width = 160  # Fixed width for the window
        window_height = @menu_items.length * item_height + 32  # Add padding

        # Position the window at the bottom right of the title screen
        window_x = WIDTH - window_width - 16
        window_y = HEIGHT - window_height - 16

        @window = Window.new window_x, window_y, window_width, window_height

        # Create contents bitmap for the window
        win_cont = Bitmap.new window_width - 16, window_height - 32  # Subtract border size

        # Draw each menu item
        @menu_items.each_with_index do |item, index|
          y_pos = index * item_height
          win_cont.draw_text 8, y_pos, window_width - 32, item_height, item
        end

        @window.contents = win_cont

        # Initialize selected item index
        @selected_index = 0

        # Draw the initial menu with selection
        update_menu_display
      end

      def update
        # Handle menu navigation
        if Input.trigger?(Input::DOWN) && @selected_index < @menu_items.length - 1
          @selected_index += 1
          update_menu_display
        elsif Input.trigger?(Input::UP) && @selected_index > 0
          @selected_index -= 1
          update_menu_display
        end

        # Handle menu selection
        if Input.trigger?(Input::C)  # C is usually the confirm button (like Enter/Z)
          case @selected_index
          when 0  # New Game
            # TODO: Implement new game logic
          when 1  # Continue
            # TODO: Implement continue game logic
          when 2  # Shutdown
            exit
          end
        end
      end

      private

      def update_menu_display
        # Redraw the menu with the currently selected item highlighted
        window_width = @window.width
        window_height = @window.height
        item_height = 24

        # Create a new bitmap for the window contents
        win_cont = Bitmap.new window_width - 16, window_height - 32

        # Draw each menu item, highlighting the selected one
        @menu_items.each_with_index do |item, index|
          y_pos = index * item_height

          # Draw selection cursor or highlight for the selected item
          if index == @selected_index
            win_cont.draw_text 0, y_pos, 8, item_height, ">"  # Simple cursor
          end

          win_cont.draw_text 8, y_pos, window_width - 32, item_height, item
        end

        @window.contents = win_cont
      end
    end
  end

  attr_reader :db, :map_tree

  def initialize args
    @db = LCF::Database.new File.open "#{GAME_DIR}/RPG_RT.ldb"
    @map_tree = LCF::MapTree.new File.open "#{GAME_DIR}/RPG_RT.lmt"
    @scenes = []
    push Scene::Title.new self
  end

  def push scene
    @scenes.push scene
  end

  def start
    loop do
      @scenes.last.update
      Input.update
      Graphics.update
    end
  rescue RGSS::Timeout
  end
end
