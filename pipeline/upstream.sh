# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# The OpenRailwayMap-vector commit the packs and the app's style assets are built from. Sourced by
# build-country.sh and build-sprites.sh. The committed style, legend and sprites must match the
# tiles in the packs, so the upstream version is pinned: after changing ORM_REF, regenerate the
# assets (see INSTALL.md) and rebuild every pack. Set ORM_REF in the environment to try another
# commit or branch.

ORM_REF="${ORM_REF:-b9c9b554a571bcf2c64077bf4d01301e135e435f}" # 2026-10-12, "News October 2026 (#1140)"
ORM_REPO="https://github.com/hiddewie/OpenRailwayMap-vector.git"

# Clone upstream into $1 if it is missing, and check out ORM_REF.
checkout_upstream() {
  local dir="$1"
  if [[ ! -d "$dir/.git" ]]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$ORM_REPO"
  fi
  if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$ORM_REF" ]]; then
    git -C "$dir" fetch -q --depth 1 origin "$ORM_REF"
    git -C "$dir" checkout -q --detach FETCH_HEAD
  fi
  echo "OpenRailwayMap-vector at $(git -C "$dir" log -1 --format='%h %cs %s')"
}
