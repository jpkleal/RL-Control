# project-setup

Control repo that ties together the 3 project repos, sets up the shared
directories between them, and runs the simulator/GUI stack + the projects
themselves.

This repo does **not** use git submodules. It only tracks scripts and
config; the actual project repos are cloned locally by `setup.sh` and are
git-ignored here, so each one is worked on normally with its own git
history/remote.

## What's tracked here

```
project-setup/
├── manifest.conf        # repo URLs/branches/tags, tool versions, shared dirs, symlink map, run order - edit this
├── setup.sh             # check tools, clone/update the 3 repos (tag or branch tip), poetry install, symlinks, versions.json
├── run.sh               # run one service, or all in sequence
├── campaign.sh          # measurement runs: K independent runs, safe shutdown, artifacts stored + exported
├── docker-ctl.sh         # up/down/status for the simulator+GUI stack
├── docker-compose.yml    # simulator + GUI services
├── .gitignore
└── lib/
    ├── common.sh         # log()/err() helpers
    └── monitor.sh        # resource sampler used by run.sh --monitor
```

## What gets created locally (not tracked here)

```
├── LyNCh/                # cloned repo (branch: main)
├── RL-Engine/             # cloned repo (branch: main)
├── NeonFC-SSL/            # cloned repo (branch: feat/drl)
├── campaigns/            # measurement runs stored by campaign.sh
└── shared/
    ├── results/           # real dir -> LyNCh/results, RL-Engine/results (+ versions.json)
    └── models/            # real dir -> NeonFC-SSL/runs/training/current, RL-Engine/runs/training/current
```

Each of the 3 folders above is an independent git repository with its own
remote. This control repo never tracks their contents - it just clones
them and keeps them on the tag (or branch tip) configured in `manifest.conf`.

`setup.sh` also writes `shared/results/versions.json`, describing the
environment it just configured (see [Pinning versions](#pinning-versions-tags)).

## Prerequisites

- git, with access configured for all 3 repos (SSH key or HTTPS
  credentials/token). If a repo is private, make sure you can run
  `git ls-remote <url>` for it before running `setup.sh`.
- [poetry](https://python-poetry.org/) installed and on your `PATH`, with the
  major.minor version given by `POETRY_VERSION` in `manifest.conf` (2.5).
- `python<PYTHON_VERSION>` on your `PATH` (e.g. `python3.12`), matching
  `PYTHON_VERSION` in `manifest.conf`.
- docker + the docker compose plugin, for the simulator/GUI stack.

## First-time setup

```bash
git clone <this-control-repo-url> project-setup
cd project-setup
./setup.sh
```

This will:
- check that Poetry and Python match `POETRY_VERSION` / `PYTHON_VERSION`
  (major.minor), aborting otherwise;
- check every repo **before changing anything**, aborting if a repo has
  uncommitted changes, commits that are not on the remote, or if a
  configured tag does not exist on the remote;
- for each repo in `manifest.conf`, clone it (or update it, if already
  present) and check out its tag, or the tip of its branch if no tag is set;
- run `poetry env use python<PYTHON_VERSION>` and `poetry install` inside it.

Then it creates `shared/results` and `shared/models`, and symlinks:

| Project path                              | Shared dir       |
|--------------------------------------------|-------------------|
| `LyNCh/results`                            | `shared/results` |
| `RL-Engine/results`                        | `shared/results` |
| `NeonFC-SSL/runs/training/current`         | `shared/models`  |
| `RL-Engine/runs/training/current`          | `shared/models`  |

Finally it writes `shared/results/versions.json`.

Safe to re-run any time - it moves repos to their configured tag (or the
latest commit on their branch), re-runs `poetry install`, and
re-checks/re-creates symlinks without touching them if they're already
correct. It never discards local work: a repo with uncommitted or unpushed
changes makes it abort without modifying anything.

## Pinning versions (tags)

Each `REPOS` entry is `"name|git_url|branch|tag|local_folder"`. The tag a
repo is checked out at is, in order of precedence:

1. the entry's own `tag` field;
2. `EXPERIMENT_TAG`, applied to every entry whose `tag` is empty;
3. none - the repo follows the tip of `branch` (development mode, **not
   reproducible**).

Only tags are supported (no commit SHAs). A configured tag that does not
exist on the remote is an error - there is no silent fallback to the branch.

To pin a new version of the experiment:

```bash
# in each of the 3 repos (annotated tag, same name everywhere)
git tag -a tgc-exp-01 -m "short description"
git push origin tgc-exp-01

# here
#   manifest.conf: EXPERIMENT_TAG="tgc-exp-01"
git commit -am "pin tgc-exp-01" && ./setup.sh
```

Suggested naming: `tgc-exp-NN`. To go back to development mode, set
`EXPERIMENT_TAG=""` (and clear any per-entry tags) and re-run `./setup.sh`.

### `shared/results/versions.json`

Written by every successful `setup.sh` (overwritten each time; a failed
setup leaves the previous file untouched). It records:

- `pinned` - true only if all 3 repos are on a tag;
- `experiment_tag`;
- per repo: `branch`, configured `tag`, `resolved_tag`, `sha`, `dirty`,
  and the Python version of its Poetry environment;
- `rl_control`: this repo's `sha`, `dirty`, and SHA-256 of `manifest.conf`
  and of each `configs/*.toml`;
- the Poetry version.

It describes the environment **as configured by setup**, not each training
run. For a run whose results will be reported: run `./setup.sh` right
before it, do not edit code or `configs/` until it finishes, and copy
`versions.json` next to that run's results (the next setup overwrites it).

## Running

Start the simulator/GUI stack once, and leave it running:

```bash
./docker-ctl.sh up        # start (no-op if already running)
./docker-ctl.sh status    # check whether it's running
./docker-ctl.sh down       # stop it when you're actually done
```

`run.sh` refuses to run anything if it detects this stack isn't up.

Run the full pipeline in one terminal - all 3 services start **in
parallel**. Each gets a colored `[name]` prefix so the interleaved output
stays readable, and each also writes its raw output to its own log file
under `logs/` (e.g. `logs/LyNCh.log`):

```bash
./run.sh
```

### Or: one terminal window per service

If you'd rather keep each service fully separate - its own window/tab,
no interleaving at all - open 3 terminal windows (or tabs, or splits in
whatever terminal app you use) and run one service in each:

```bash
# window 1
./run.sh LyNCh

# window 2
./run.sh NeonFC-SSL

# window 3
./run.sh RL-Engine
```

Each still checks that the docker stack is up before starting, runs
independently of the others, and still logs its raw output to
`logs/<folder>.log`. Ctrl-C in any window stops just that service.

Or run just one service at a time, e.g. while debugging - Ctrl-C to stop
it, edit code, run again, without touching the other services or the
docker stack:

```bash
./run.sh LyNCh
./run.sh NeonFC-SSL
./run.sh RL-Engine
```

## Resource monitor (`--monitor`)

For stress tests, `run.sh` can sample the resources of the services it
starts:

```bash
./run.sh --monitor                          # all services -> logs/monitor.csv
./run.sh RL-Engine --monitor                # one service  -> logs/monitor_RL-Engine.csv
MONITOR_INTERVAL=10 ./run.sh --monitor      # sample every 10 s (default 60)
```

Without `--monitor` nothing extra runs. With it, `lib/monitor.sh` starts
right after the services of each stage, takes a first sample immediately and
then one every `MONITOR_INTERVAL` seconds, and stops when the stage ends. It
also stops if `run.sh` is interrupted or killed, so it is never left behind.

The CSV (recreated on every run, like the service logs) has one row per
service per sample, summed over the service's whole process tree (NeonFC's
layer processes included, plus the `script`/`poetry` wrappers):

| Column | Meaning |
|--------|---------|
| `time_unix` | sample time (seconds since epoch) |
| `service` | service folder; `_disk` rows carry only `checkpoints_kb` |
| `n_procs` | processes in the tree (`0` once, when the service has exited) |
| `rss_kb` | resident memory, summed |
| `cpu_pct` | `ps` %CPU, summed |
| `threads` | threads, summed |
| `fds` | open file descriptors (`lsof`) |
| `sockets` | open network sockets (`lsof -i`) |
| `checkpoints_kb` | size of `RL-Engine/runs/training/checkpoints` (only when RL-Engine is monitored) |

Per-epoch timing (request, file close, response, ingestion, updates) is
written separately by RL-Engine to `shared/results/timing.jsonl`, on every
run.

## Measurement runs (`campaign.sh`)

`campaign.sh` runs complete, independent measurement runs and stores their
artifacts. Pin the code first (same annotated tag pushed in the 4 repos,
`EXPERIMENT_TAG` set in `manifest.conf`), run `./setup.sh`, check
`"pinned": true` in `shared/results/versions.json`, and start the docker
stack. Then:

```bash
./campaign.sh --epochs 500 --runs 5                  # 5 independent runs of 500 epochs
./campaign.sh --epochs 2000 --name stress-01         # one long run (stress test)
./campaign.sh --epochs 500 --runs 5 --export /mnt/out --interval 30
```

For every run it:

1. **cleans the state of earlier runs** so runs are independent:
   `RL-Engine/runs/training/checkpoints`, `RL-Engine/runs/training/index.jsonl`
   and `RL-Engine/runs/tensorboard` (otherwise RL-Engine resumes from the last
   checkpoint and TensorBoard mixes runs), the contents of `shared/models/`
   and of `shared/results/` (except `versions.json`), and `logs/`. Symlinks
   and the cloned repos are left untouched;
2. starts LyNCh, waits for its port, starts NeonFC-SSL, waits for its port,
   then RL-Engine with `--epochs N`, plus the resource monitor;
3. waits for RL-Engine to finish (a server dying earlier fails the run);
4. **stops every service as a whole process group** - INT, then TERM after
   20 s, then KILL after 10 s more - and checks the ports were released;
5. stores the artifacts in `campaigns/<name>/run-<k>/` and exports
   `campaigns/<name>/run-<k>.tar.gz` (also copied to `--export DIR`):

```
run-<k>/
├── versions.json      # setup record (tags, SHAs, config hashes)
├── timing.jsonl       # per-epoch timings (RL-Engine)
├── summaries/         # <scenario>.jsonl - per-batch summaries (LyNCh)
├── archive/           # transitions files, only with archive_dir enabled
├── tensorboard/       # RL-Engine TensorBoard events
├── monitor.csv        # resource samples
├── logs/              # service logs
└── env.txt            # host, CPU/RAM/GPU, Python/Poetry/Docker/torch, image digests
```

Ctrl-C (or TERM) stops the current run the same way and stores what it
produced, marked `interrupted` in `env.txt`. A failed run stops the
campaign. Existing `run-<k>` folders are never overwritten. To keep the
transitions files, uncomment `archive_dir` in `configs/rlengine.toml`
(~1 MB per episode before compression).

`./run.sh --monitor` is still available for interactive sessions; it does
not clean state, stop servers on its own or store artifacts.

## Changing branches, tags, repos, or run order

Everything is in `manifest.conf` - edit it, commit the change to this
control repo, and re-run `./setup.sh`. Nobody needs to touch the scripts
themselves for routine changes like a new default branch or a new tag.

## Troubleshooting

**`fatal: Remote branch <x> not found in upstream origin`**
Usually means either you're not authenticated for a private repo, or the
branch name in `manifest.conf` doesn't match exactly (case, `feat/x` vs
`x`, etc). Run `git ls-remote --heads <repo-url>` to see the real branch
list and confirm which it is. If a clone fails partway, delete the
partial folder (e.g. `rm -rf NeonFC-SSL`) before re-running `setup.sh`.

**`has uncommitted changes` / `has commits that are not on the remote`**
`setup.sh` refuses to move a repo that holds local work. Commit and push
(or stash / discard) the listed changes in that repo, then re-run.

**`tag '<x>' does not exist on the remote`**
The tag was not created or not pushed in that repo
(`git push origin <x>`), or the name in `manifest.conf` is misspelled.
Check with `git ls-remote --tags <repo-url>`.

**`Poetry 2.5.x required` / `python3.12 not found`**
Install the versions given in `manifest.conf` (`POETRY_VERSION`,
`PYTHON_VERSION`), or update those values if the project moved on.
