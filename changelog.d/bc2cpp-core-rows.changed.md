- The closed bc2cpp build keeps a core method that the engine reaches only through calls on a proven receiver as a
  row outside the method table: 35 core entries (`Time#year`, `String#split`, `Array#pack`, ...) leave the closed host
  table (741 -> 706; 686 on master with SUPER_DIRECT).
