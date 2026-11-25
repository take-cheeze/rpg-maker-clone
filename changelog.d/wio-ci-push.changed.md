- **CI builds the Wio firmware again** on pushes to `master` and manual
  dispatch: `scripts/wio/build.bash` builds the closed-world wio libmruby,
  uni-algo and `pio run -e wio` from a bare checkout, and `wio-renode` boots
  the result. The size report shows how far the image overflows the flash.
