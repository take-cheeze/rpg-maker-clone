- **MZ's messages are operated, and its choices branch.** `--mz_message_play`
  (`MZ_MODE=message_play`) shows a message and a two-way choice, pages the text
  through with confirm, moves the cursor to the *second* entry and confirms it,
  then checks which branch of the event actually ran — each branch writes a
  different value to the same variable, so the value names the branch. The
  existing message check only asserted that a window opened over the map, which
  says nothing about the window taking input, closing again, or the interpreter
  acting on the answer; Show Choices had never run at all, so `Window_ChoiceList`
  and the interpreter's branch skipping were untested. Moving the cursor is what
  makes it bite: the first entry is the default, so a probe that only tapped
  confirm would see a choice window, a closed message and a branch having run
  without a choice ever being made.
