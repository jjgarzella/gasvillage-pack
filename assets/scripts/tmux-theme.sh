#!/bin/sh
# tmux-theme.sh — Gas Village session theme.
#
# Slim version of Gas Town's tmux-theme.sh: enables mouse + clipboard
# and paints a minimal status bar. No tier-aware coloring, no
# session-name-shape inference — Gas Village uses one theme for all
# session types.
#
# Usage: tmux-theme.sh <session> <agent> <config-dir>

SESSION="$1" AGENT="$2" CONFIGDIR="$3"

# Socket-aware tmux command (uses GC_TMUX_SOCKET when set).
gcmux() { tmux ${GC_TMUX_SOCKET:+-L "$GC_TMUX_SOCKET"} "$@"; }

# Minimal status bar.
gcmux set-option -t "$SESSION" status-position bottom
gcmux set-option -t "$SESSION" status-style "bg=#2d3748,fg=#e0e0e0"
gcmux set-option -t "$SESSION" status-left-length 25
gcmux set-option -t "$SESSION" status-left "● $AGENT "
gcmux set-option -t "$SESSION" status-right-length 40
gcmux set-option -t "$SESSION" status-right "%H:%M"

# Mouse + clipboard. The whole reason this script runs.
gcmux set-option -t "$SESSION" mouse on
gcmux set-option -t "$SESSION" set-clipboard on
