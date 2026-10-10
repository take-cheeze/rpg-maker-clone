- bc2cpp site census: the exact receiver-origin walk now models every ENTER slot and EXCEPT, reports joins as may-sets and
  labels call, operator and index results by their writing op (ADR 0379). Unknown receiver origins in the wio shipped pass
  fall from 527 to 9; generated C++ is byte-identical.
