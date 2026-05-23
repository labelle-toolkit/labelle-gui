#!/usr/bin/env bash
# labelle-gui launcher — opens a project at startup with a flow tab
# already focused. Defaults to bouncing-ball / hit_counter.flow.jsonc so
# a fresh `./scripts/load-bouncing-ball.sh` from the labelle-gui repo
# drops you straight into the canonical demo.
#
# Usage:
#   ./scripts/load-bouncing-ball.sh
#   ./scripts/load-bouncing-ball.sh <project-dir>
#   ./scripts/load-bouncing-ball.sh <project-dir> <flow-path>
#
# Both positional args are optional. If only the project is given, the
# script auto-discovers the first `.flow.jsonc` under
# `<project>/scripts/flows/` and opens it.

set -euo pipefail

# Resolve the labelle-gui repo root (this script lives at <repo>/scripts/).
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
GUI_REPO="$( cd "$SCRIPT_DIR/.." && pwd )"
TOOLKIT_ROOT="$( cd "$GUI_REPO/.." && pwd )"

# Defaults — bouncing-ball is the canonical end-to-end demo and ships
# `scripts/flows/hit_counter.flow.jsonc` (2-node Event + ChangeVariable
# flow per RFC-FLOW-VOCABULARY). Override either by passing args.
DEFAULT_PROJECT="$TOOLKIT_ROOT/bouncing-ball"
PROJECT="${1:-$DEFAULT_PROJECT}"

if [[ ! -d "$PROJECT" ]]; then
  echo "load-bouncing-ball: project not found: $PROJECT" >&2
  exit 1
fi
if [[ ! -f "$PROJECT/project.labelle" ]]; then
  echo "load-bouncing-ball: $PROJECT has no project.labelle" >&2
  exit 1
fi

# Resolve the flow: explicit arg wins; otherwise pick the first
# `.flow.jsonc` under `scripts/flows/`. If no flows live in the project,
# launch the GUI with the project loaded but no tab focused — the user
# can browse the tree.
FLOW="${2:-}"
if [[ -z "$FLOW" ]]; then
  if [[ "$PROJECT" == "$DEFAULT_PROJECT" ]]; then
    FLOW="$PROJECT/scripts/flows/hit_counter.flow.jsonc"
  else
    FLOW="$( find "$PROJECT/scripts/flows" -maxdepth 1 -type f -name '*.flow.jsonc' 2>/dev/null | head -n 1 || true )"
  fi
fi

cd "$GUI_REPO"

# Build incrementally — `zig build` is a no-op when sources are
# unchanged, so launching this script feels instant on a warm tree.
echo "load-bouncing-ball: building labelle-gui…" >&2
zig build

GUI_BIN="$GUI_REPO/zig-out/bin/labelle-gui"
if [[ ! -x "$GUI_BIN" ]]; then
  echo "load-bouncing-ball: built but $GUI_BIN missing/not executable" >&2
  exit 1
fi

ARGS=(--project "$PROJECT")
if [[ -n "$FLOW" && -f "$FLOW" ]]; then
  ARGS+=(--open-flow "$FLOW")
  echo "load-bouncing-ball: project=$PROJECT  flow=$FLOW" >&2
else
  if [[ -n "$FLOW" ]]; then
    echo "load-bouncing-ball: flow not found: $FLOW (launching with project only)" >&2
  fi
  echo "load-bouncing-ball: project=$PROJECT  (no flow tab)" >&2
fi

exec "$GUI_BIN" "${ARGS[@]}"
