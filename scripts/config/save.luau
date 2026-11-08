-- Save numbers (spec §3, §14, §16.3). `file` is a save name for rtype.Persistence (1-64 letters, digits, _ - .); the folder
-- is `persistence.folder` in project.luau, keep in step with `folder` here.
return {
  file = "gridmind.save",
  folder = "gridmind",
  autosaveSeconds = 30, -- spec §3: autosave every 30 s of real time (and on quit)
  modal = { width = 560, padding = 24, gap = 10, buttonWidth = 210, lineChars = 62 },
}
