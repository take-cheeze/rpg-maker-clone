- **RPG2000/2003:** an LCF record or table read from memory (a map's events
  and pages, a database row) now keeps only its bytes: a field is found and
  decoded when it is read, and the first write splits the record into its
  chunks. A table keeps each row as its offset until the row is read, and a
  long database row (a common event) leaves its large chunks in the file.
