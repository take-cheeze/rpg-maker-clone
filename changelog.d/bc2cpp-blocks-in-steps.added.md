bc2cpp: a resumable step can call a suspendable method with a block whose body yields to the Fiber; the C++ Fiber CALLs the block's step.
