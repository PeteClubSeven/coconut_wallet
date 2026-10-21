#!/usr/bin/env bash
# Run the Ark faucet repo's regtest stack (bitcoind, electrs, mempool, captaind,
# watchmand, CLN, bark, faucet) for Coconut Wallet development, with
# ./compose.override.yml on top. Runs as its own compose project so it never
# touches a stack started from the faucet repo itself. See ./README.md.
#
#   ./regtest.sh up -d --build      start (first build compiles captaind etc.)
#   ./regtest.sh fund [BTC]         fund captaind, faucet and watchman
#   ./regtest.sh <compose args>     anything else, e.g. ps, logs -f captaind, down
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# Checkout of https://gitlab.com/ark-bitcoin/faucet; defaults to a sibling of
# this repo or of its parent directory.
if [[ -z "${FAUCET_DIR:-}" ]]; then
    for candidate in "$REPO_ROOT/../faucet" "$REPO_ROOT/../../faucet"; do
        if [[ -f "$candidate/docker-compose.yml" ]]; then
            FAUCET_DIR="$candidate"
            break
        fi
    done
fi
if [[ ! -f "${FAUCET_DIR:-}/docker-compose.yml" ]]; then
    echo "Faucet repo not found. Clone https://gitlab.com/ark-bitcoin/faucet next to this repo," >&2
    echo "or set FAUCET_DIR to its path." >&2
    exit 1
fi
FAUCET_DIR="$(cd "$FAUCET_DIR" && pwd)"

export COMPOSE_PROJECT_NAME=coconut-regtest
export COCONUT_REGTEST_DIR="$HERE"
export COMPOSE_FILE="$FAUCET_DIR/docker-compose.yml:$HERE/compose.override.yml"

cd "$FAUCET_DIR"
if [[ "${1:-}" == "fund" ]]; then
    shift
    exec bash contrib/docker/fund.sh "$@"
fi
exec docker compose "$@"
