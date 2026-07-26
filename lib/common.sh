#!/usr/bin/env bash
# common.sh - tiny shared helpers for setup.sh / run.sh

log()  { echo -e "[setup] $*"; }
err()  { echo -e "[setup][ERROR] $*" >&2; }
