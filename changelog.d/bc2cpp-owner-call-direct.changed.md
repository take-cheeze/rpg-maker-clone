bc2cpp: an owner call no longer keeps engine methods in the closed build's method tables when it covers every
engine owner it lists. It covers an owner by testing its exact class in the guard chain before it (nothing
subclassing it), or by carrying the owner's compiled entry (`OWNER_CALL_DIRECT`), which it finds by walking the
receiver's ancestors itself. The subclass scan also stops reading comments, check-script fixtures and a native
class's own name as superclasses.
