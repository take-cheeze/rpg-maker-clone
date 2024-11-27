# From: https://github.com/uni-algo/uni-algo?tab=readme-ov-file#normalization-functions
assert "" do
  assert_equal RGSS.to_nfd("Ŵ"), "W\u0302"
end
