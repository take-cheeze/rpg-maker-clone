- **Wio**: methods are installed from ROM method tables at boot. Compiled class bodies, Fiber, IO and StringIO no
  longer define methods at run time, and a class gets a heap method table only when something defines a method on it
  at run time. Heap in use after gem init is about 4.3 KB smaller, and the heap's extent about 7 KB smaller.
