#!/usr/bin/env bash
# Bash launcher for Linux, WSL, and macOS.
# Builds the TUI in a separate output directory and restores terminal settings on exit.

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

for command in erl rebar3; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Missing %s. Install Erlang/OTP 28+ and Rebar3 in this Linux environment.\n' "$command" >&2
        exit 1
    fi
done

if [[ ! -t 0 ]]; then
    printf 'Run this launcher in an interactive terminal.\n' >&2
    exit 1
fi

# Keep Linux builds separate when WSL shares the checkout with Windows.
export REBAR_BASE_DIR="${REBAR_BASE_DIR:-$PWD/_build/unix}"
rebar3 compile

shopt -s nullglob
code_paths=("$REBAR_BASE_DIR"/default/lib/*/ebin)

# Let the TUI receive Ctrl+Q (XON) and Ctrl+C (terminal interrupt) as input.
terminal_settings=$(stty -g)
trap 'stty "$terminal_settings" || true' EXIT
stty -ixon intr undef

erl -noshell -pa "${code_paths[@]}" -config config/sys \
    -eval 'case erl_harness_tui:run() of ok -> halt(0); Error -> io:format(standard_error, "~p~n", [Error]), halt(1) end.'
