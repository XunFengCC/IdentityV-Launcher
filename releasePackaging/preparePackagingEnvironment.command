#!/bin/zsh
# Prepare an isolated, project-local environment for deterministic Finder DMG
# metadata generation. This never installs anything system-wide.
set -euo pipefail

script_dir=${0:A:h}
venv_root="$script_dir/.venv"
requirements="$script_dir/requirements-dmg.txt"
python3_path="$(command -v python3 || true)"

[[ -f "$requirements" ]] || { print -u2 -- "Missing $requirements"; exit 1; }
[[ -n "$python3_path" ]] || { print -u2 -- "Python 3 is required."; exit 1; }

if [[ ! -x "$venv_root/bin/python3" ]]; then
  "$python3_path" -m venv "$venv_root"
fi

"$venv_root/bin/python3" -m pip install \
  --disable-pip-version-check \
  --requirement "$requirements"

"$venv_root/bin/python3" -m pip show dmgbuild | /usr/bin/awk '/^Name:|^Version:/{print}'
