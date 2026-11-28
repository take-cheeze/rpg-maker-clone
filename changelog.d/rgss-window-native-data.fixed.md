- **bc2cpp builds no longer embed `RGSS::Window` ivars** in the object's data
  slot, where the native window node also lives. Any class that native code
  makes a data object now keeps its ivars in the ordinary table.
