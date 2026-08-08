s = Sprite.new
s.bitmap = Bitmap.new ARGV[0]

loop do
  Input.update
  Graphics.update
end
