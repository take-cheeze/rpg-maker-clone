- **Events:** A Change Actor Name event command with a blank name now
  genuinely clears the actor's displayed name, matching RPG_RT. Previously
  a blank name was silently ignored and the actor kept their old name;
  the sibling Change Actor Title command already got this right. Covered
  by a corrected `scripts/rpg2k_logic_check.rb` check.
