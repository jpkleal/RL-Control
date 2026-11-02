# RL-Control — Agent Reference

Lightweight orchestration repo. Centralizes running the 3 sub-repos and shared folder setup. Does not contain ML logic.

---

## Commands

| Command | Purpose |
|---------|---------|
| `./setup.sh` | Run **once** on fresh machine. Clones 3 sub-repos, runs `poetry install` in each, creates `shared/` dirs and symlinks. Idempotent — safe to re-run. |
| `./docker-ctl.sh up` | Starts simulator/GUI stack (ER-Force + SSL-Vision + AutoRef + GameController). Leave running. |
| `./docker-ctl.sh status` | Verify stack is up. |
| `./docker-ctl.sh down` | Stop stack when done. |
| `./run.sh` | Run all 3 services in parallel (colored output, logged to `logs/`). |
| `./run.sh LyNCh` | Run only Lynch (harness). |
| `./run.sh NeonFC-SSL` | Run only NeonFC (robot controller). |
| `./run.sh RL-Engine` | Run only RL-Engine (trainer). |

---

## Sub-Modules (each has its own `agents.md`)

| Module | Role |
|--------|------|
| **NeonFC-SSL** | Robot environment communicator & controller. Runs DRL policy (`DRLCoach`), streams transitions, receives control events. |
| **LyNCh** | Test/episode framework. Resets sim, collects NeonFC transitions, assigns reward/done, writes history JSONL. |
| **RL-Engine** | SAC/PPO trainer. Drives Lynch, ingests history files, writes model checkpoints. |

---

## Manifest Contract (`manifest.conf`)

Single source of truth. Edit here, commit, re-run `./setup.sh`.

| Section | Controls |
|---------|----------|
| `REPOS` | Name, git URL, branch, local folder for each sub-repo |
| `SHARED_DIRS` | Real directories under `shared/` (`results`, `models`) |
| `SYMLINKS` | Project path → shared dir mapping (4 entries) |
| `RUN_STAGES` | Parallel service groups (semicolon-separated) |

---

## Ports & Data Flow

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 10001 | TCP | NeonFC → Lynch | Transition stream (state, action, next_state) |
| 10002 | TCP | Lynch → NeonFC | ModelUpdate (weights), MasterState (play/stop) |
| 10003 | TCP | RL-Engine → Lynch | Training commands (test_case, epochs) |
| 10300 | UDP | Lynch → Simulator | SimulatorCommand (teleport) |
| 10301 | UDP | NeonFC → Simulator | RobotControl (Blue team velocities) |
| 10020 | UDP (multicast) | Sim → AutoRef → NeonFC | SSL-Vision packets (224.5.23.2) |
| 10010 | UDP (multicast) | AutoRef → NeonFC | Tracked objects / referee decisions |

Shared directories (via symlinks):
- `LyNCh/results` ↔ `shared/results`
- `RL-Engine/results` ↔ `shared/results`
- `NeonFC-SSL/runs/training/current` ↔ `shared/models`
- `RL-Engine/runs/training/current` ↔ `shared/models`

---

## Startup Sequence (Hard Dependency Order)

```
1. ./docker-ctl.sh up          # ER-Force + SSL-Vision + AutoRef + GameController (run once, leave running)
2. ./run.sh LyNCh              # Lynch — TCP server on :10002 (NeonFC), :10003 (RL-Engine), UDP :10300 (sim)
3. ./run.sh NeonFC-SSL         # NeonFC — connects to Lynch :10002, subscribes to vision/referee
4. ./run.sh RL-Engine          # RL-Engine — connects to Lynch :10003, sends training config
```

**Why this order:** Lynch is the TCP server; NeonFC & RL-Engine are clients that must connect to it. Simulator stack provides vision/referee multicast.

---

## Common Operations

| Task | Steps |
|------|-------|
| Switch NeonFC branch | Edit `manifest.conf` `REPOS` line for NeonFC-SSL → `./setup.sh` |
| Re-symlink after restructure | `./setup.sh` (re-checks/re-creates symlinks) |
| View live logs for one service | `tail -f logs/<Module>.log` (e.g., `logs/NeonFC-SSL.log`) |
| Clean slate (nuke & restart) | `./docker-ctl.sh down` → `rm -rf LyNCh NeonFC-SSL RL-Engine shared logs` → `./setup.sh` → `./docker-ctl.sh up` → run sequence above |

---

## Troubleshooting (Quick)

| Symptom | First Checks |
|---------|--------------|
| Training won't start | 1. `./docker-ctl.sh status` 2. Ports free? (`netstat -tlnp \| grep -E '1000[1-3]\|1030[0-1]'`) 3. `shared/` symlinks exist? |
| "Address already in use" | `pkill -f lynch; pkill -f neonfc; pkill -f train` then retry |
| Services desync | Check `logs/` for connection errors; verify Lynch started first (it's the TCP server) |
| Simulator issues | `./docker-ctl.sh down && ./docker-ctl.sh up`; check `docker compose logs` |

---

## Decision Ownership (Cross-Repo)

| Decision | Owner Repo | Where to Change |
|----------|------------|-----------------|
| State vector dimension | RL-Engine | `config.toml` `state_dim` + NeonFC `DRLCoach` + Lynch `EnvManager` |
| Action space | RL-Engine | `config.toml` `action_dim` + NeonFC `DRLCoach` |
| Robot IDs / roles | RL-Engine | `config.toml` `role_ids` (used by all) |
| Scenario / curriculum | LyNCh | `test_config.yaml` + `scenarios/*.json`; RL-Engine `test_case` must match |
| Checkpoint format | RL-Engine | `SaveSystem.save()` + NeonFC `DRLCoach.load_checkpoint()` |
| Port allocation | RL-Control | `manifest.conf` (docs) + each service's config |

---

> **Note:** Each sub-repo (`LyNCh/`, `NeonFC-SSL/`, `RL-Engine/`) has its own `agents.md` with module-specific details.