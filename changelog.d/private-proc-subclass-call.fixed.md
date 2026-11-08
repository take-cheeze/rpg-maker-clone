- **Compiled sends:** `obj.name(*args)` on an explicit receiver now raises
  `NoMethodError` for a private or protected method, as the interpreter does (a
  splat send skipped the check), so `private :call` on a `Proc` subclass is
  honoured by a compiled `proc.call(*args)`.
