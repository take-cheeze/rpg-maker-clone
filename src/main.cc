#include <mruby.h>
#include <cstdlib>
#include <memory>

int main() {
  std::unique_ptr<mrb_state, decltype(&mrb_close)> M(mrb_open(), mrb_close);
  return EXIT_SUCCESS;
}
