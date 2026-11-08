# Running the game on an engine release

`tools/engine.sh` pulls an `aylo-runtime` build from the `Charles-Mahoudeau/rtype` GitHub releases into a cache
directory (default `~/.cache/hackathon-rubix/engine`, override with `AYLO_ENGINE_CACHE`) and runs the game on it.
It needs the GitHub CLI (`gh auth login`) and `unzip`.

```sh
tools/engine.sh engine_pull          # download + SHA256SUMS check + extract (no-op if that build is already cached)
tools/engine.sh run                  # windowed client (pulls first if needed)
tools/engine.sh run --server --ticks 600   # extra args go to aylo-runtime
tools/engine.sh test                 # M0 headless self-test via tools/run_engine_test.sh
tools/engine.sh path                 # print the aylo-runtime path (e.g. for AYLO_RUNTIME=$(tools/engine.sh path))
```

Version: `-v <nightly|tag>` flag, else `AYLO_ENGINE_VERSION`, else the first line of `tools/engine.version` if that
file exists, else `nightly`. `nightly` is rolling, so `engine_pull` asks GitHub for the current build each time and
only downloads when it is not cached; offline, the last pulled build of that version is used.
