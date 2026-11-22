- **bc2cpp**: a call to a method with a single definition now raises
  NoMethodError on nil or on an object of an unrelated class, as the
  interpreter does. Before, the compiled direct call ran the method anyway.
  The call stays unguarded where the receiver is proven to reach the method.
