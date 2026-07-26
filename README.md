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
├── manifest.conf        # repo URLs/branches, shared dirs, symlink map, run order - edit this
├── setup.sh             # clone/update the 3 repos, poetry install, build symlinks
├── run.sh               # run one service, or all in sequence
├── docker-ctl.sh         # up/down/status for the simulator+GUI stack
├── docker-compose.yml    # simulator + GUI services
├── .gitignore
└── lib/
    └── common.sh         # log()/err() helpers
```

## What gets created locally (not tracked here)

```
├── LyNCh/                # cloned repo (branch: main)
├── RL-Engine/             # cloned repo (branch: main)
├── NeonFC-SSL/            # cloned repo (branch: feat/drl)
└── shared/
    ├── results/           # real dir -> LyNCh/results, RL-Engine/Results
    └── models/            # real dir -> NeonFC-SSL/models, RL-Engine/runs/training/current
```

Each of the 3 folders above is an independent git repository with its own
remote. This control repo never tracks their contents - it just clones
them and keeps them on the branch configured in `manifest.conf`.

## Prerequisites

- git, with access configured for all 3 repos (SSH key or HTTPS
  credentials/token). If a repo is private, make sure you can run
  `git ls-remote <url>` for it before running `setup.sh`.
- [poetry](https://python-poetry.org/) installed and on your `PATH`.
- docker + the docker compose plugin, for the simulator/GUI stack.

## First-time setup

```bash
git clone <this-control-repo-url> project-setup
cd project-setup
./setup.sh
```

This will, for each repo in `manifest.conf`:
- clone it (or update it, if already present) and check out the configured branch
- run `poetry install` inside it

Then it creates `shared/results` and `shared/models`, and symlinks:

| Project path                              | Shared dir       |
|--------------------------------------------|-------------------|
| `LyNCh/results`                            | `shared/results` |
| `RL-Engine/Results`                        | `shared/results` |
| `NeonFC-SSL/models`                        | `shared/models`  |
| `RL-Engine/runs/training/current`          | `shared/models`  |

Safe to re-run any time - it updates repos to latest on their branch,
re-runs `poetry install`, and re-checks/re-creates symlinks without
touching them if they're already correct.

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

## Changing branches, repos, or run order

Everything is in `manifest.conf` - edit it, commit the change to this
control repo, and re-run `./setup.sh`. Nobody needs to touch the scripts
themselves for routine changes like a new default branch.

## Troubleshooting

**`fatal: Remote branch <x> not found in upstream origin`**
Usually means either you're not authenticated for a private repo, or the
branch name in `manifest.conf` doesn't match exactly (case, `feat/x` vs
`x`, etc). Run `git ls-remote --heads <repo-url>` to see the real branch
list and confirm which it is. If a clone fails partway, delete the
partial folder (e.g. `rm -rf NeonFC-SSL`) before re-running `setup.sh`.
