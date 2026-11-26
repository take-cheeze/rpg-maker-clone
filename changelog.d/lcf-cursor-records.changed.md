- **RPG2000/2003** LCF records and tables held in memory (a map's events and
  pages, a database row, an event's command and move lists) are now read
  through a byte position in their String instead of a `StringIO` each, so
  loading a map no longer builds one `StringIO` per nested record.
