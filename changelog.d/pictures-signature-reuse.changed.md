- **The picture layer's change check allocates less per frame.** The signature
  it compares is filled into a reused array instead of a new one built each
  frame.
