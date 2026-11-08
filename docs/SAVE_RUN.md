# Save / load: real-runtime run (GR5-77)

Engine: `aylo-runtime` built from rtype 3e6d9cf3 (with `rtype.Persistence`), windowed client, macOS. No screenshot: the agent
run cannot watch the window, so the modals are covered by `tests/test_save.luau` (layout lint) instead.

## Windowed client, two launches

Launch 1 ran 50 s and was killed (so no quit save): the boot wrote the file, the 30 s autosave rewrote it
(`~/Library/Application Support/gridmind/gridmind.save.sav`, `game_time` 30, `saved_at` set).

Launch 2 (`aylo-runtime . --ticks 2400`, exit 0):

```
save: boot ok, tick 300, credits 500, away none
save: autosave at 30 s, ok=true
```

Tick 300 is the 30 s of launch 1: game time is restored. Credits stay 500 because the client has no decider yet (GR5-71), so
agents do not act; the credits, agents and skills round trip is `tests/test_save.luau` and the engine selftest below.

## Engine selftest (`tools/run_engine_test.sh <aylo-runtime>`)

`scripts/server/selftest.luau` runs the client's `Save` controller on the real `rtype.Persistence` plugin (folder
`gridmind-selftest`): new game written at boot, 1200 ticks played, quit save, reload equal (tick and credits), an hour away gives
the offline report and more game time, an unknown `schema_version` blocks saving and the file stays byte-identical, delete works.
Output: `selftest: PASS`.

## Not exercised in the engine

- Save on quit: the controller listens to `rtype.Closed`; a real window close was not driven (a `--ticks` exit sends `AppExit`, not
  `Closed`). Covered by `Save.quit` in the tests only.
- A file the engine reports as `corrupt`: covered by a fake storage in `tests/test_save.luau`.
