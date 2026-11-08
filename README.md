# hackathon-rubix

This game runs on the AYLO engine (`aylo-runtime`). The engine is published as GitHub releases in
[Charles-Mahoudeau/rtype](https://github.com/Charles-Mahoudeau/rtype). Use [`tools/engine.sh`](tools/engine.sh)
to download a build and start the game on it.

## Requirements

- The GitHub CLI (`gh`), logged in with `gh auth login`, with access to `Charles-Mahoudeau/rtype`
- `unzip` (or a `tar` that can read zip files)
- One of these platforms: macOS arm64, Linux x86_64 or Windows x86_64 (Git Bash, MSYS or Cygwin)

## Quick start

Run these from the repository root:

```sh
tools/engine.sh engine_pull   # download, verify and extract the latest nightly engine
tools/engine.sh run           # start the game in a window
```

`run` downloads the engine first if it is not there yet, so `tools/engine.sh run` works on its own.

## How to play and what to learn

You direct a space company by writing instructions for agents.
Open Agents, select the Miner, and edit its directive: name a vein,
when to return, and where to sell. Save it and watch the map and feed.
Check Logs for decisions and errors; missions show goals and progress.
Claim completed mission rewards to advance the main mission sequence.

At T2, buy the Scanner in the Shop and equip scan in the agent editor.
Ask the Miner to scan, then inspect the result before choosing a vein.
Use the Archive to save and assign a successful routine as a skill.
Skills repeat known steps without an AI decision for each step.
AI decisions spend Compute; buy more when needed.

Buy the Warehouse to reach T3 and store ore. Buy the Trading post
to sell at Orbis; compare prices and which goods each buyer accepts.
Give multiple Miners distinct work and watch for crowding.
With a Warehouse and Reputation 1, buy the Logistics hub for T4.
Hire Logisticians, arrange freighters, and watch for stock conflicts.
Upgrade engines and navigation to reach farther planets.
Salvage, refining, and raiding are optional purchases with different
requirements, costs, risks, and buyers; inspect their results.
At T4 with Reputation 2, buy the Command center to reach T5;
hire a Monitor to watch alerts and help workers recover.

Learn to give clear instructions, supply useful context, reuse routines,
coordinate agents, and evaluate results as conditions change.
The windowed client currently uses a deterministic keyword-based stub,
so its behavior is not a demonstration of a live language model.

## Commands

| Command | What it does |
| --- | --- |
| `tools/engine.sh engine_pull` | Download the engine release, check it against `SHA256SUMS`, extract it and print the runtime path. Nothing is downloaded if that build is already in the cache. |
| `tools/engine.sh path` | Print the path of the cached `aylo-runtime`, downloading it first if needed. |
| `tools/engine.sh run [args]` | Start the game on the cached engine. Any extra arguments go to `aylo-runtime`. |
| `tools/engine.sh test` | Run the headless M0 self-test ([`tools/run_engine_test.sh`](tools/run_engine_test.sh)). |

Examples of `run` with extra arguments:

```sh
tools/engine.sh run --server --ticks 600   # headless server that stops after 600 ticks
```

## Choosing the engine version

The script uses the first of these that is set:

1. the `-v` flag: `tools/engine.sh -v v0.1.0 run`
2. the `AYLO_ENGINE_VERSION` environment variable
3. the first line of `tools/engine.version`, if that file exists
4. `nightly`

`nightly` changes over time. On each pull, the script asks GitHub which nightly build is the current one and
downloads it only if it is not already cached. When you are offline, it uses the last build it pulled.

## Where the engine is stored

The default location is `${XDG_CACHE_HOME:-~/.cache}/hackathon-rubix/engine`. Set `AYLO_ENGINE_CACHE` to store
it somewhere else, for example in `~/Downloads`:

```sh
AYLO_ENGINE_CACHE=~/Downloads tools/engine.sh engine_pull
AYLO_ENGINE_CACHE=~/Downloads tools/engine.sh run
# or set it once for the whole shell session
export AYLO_ENGINE_CACHE=~/Downloads
```

Each build is extracted to `<cache>/aylo-engine-<version>-<platform>/`. The file `<cache>/<version>.current`
(for example `nightly.current`) records which build is the current one.

### Replacing an existing build

- If a build with the same name is already in the cache, the script prints `already pulled` and skips the download.
- If a build folder with that name exists but is broken, the script deletes it and extracts a fresh copy.
- The script never deletes older builds that have a different name.

To force a fresh download that replaces your current copy:

```sh
rm -rf ~/Downloads/aylo-engine-*-macos-arm64
AYLO_ENGINE_CACHE=~/Downloads tools/engine.sh engine_pull
```

To pull the latest build and then delete the older ones:

```sh
AYLO_ENGINE_CACHE=~/Downloads tools/engine.sh engine_pull && \
new=$(cat ~/Downloads/nightly.current) && \
for d in ~/Downloads/aylo-engine-*-macos-arm64; do [ "$(basename "$d")" = "$new" ] || rm -rf "$d"; done
```

Change `macos-arm64` to `linux-x86_64` or `windows-x86_64` on those platforms.

## Running without the script

You can also start the runtime yourself. Its first argument is the path to the game directory:

```sh
"$(tools/engine.sh path)" .                         # game window
tools/run_engine_test.sh "$(tools/engine.sh path)"  # headless self-test
```

## Troubleshooting

- **`no <platform> asset found in ... release`**: check `gh auth status`, and check that the release or tag exists.
- **`checksum mismatch`**: the download is corrupted or incomplete. Run the pull again.
- **`gh not found`**: install the GitHub CLI. A build that is already cached still works without it.

## Contributing

See [AGENTS.md](AGENTS.md). Commits must follow Conventional Commits.

For token accounting and its current limitations, see [docs/token-usage.md](docs/token-usage.md).
