#!/usr/bin/env bash
# Switch off Opal Composer's background services so nothing grabs the camera from C1 Tune:
#   ./scripts/disable-opal.sh          quit Opal and disable its login items, agents and helpers
#   ./scripts/disable-opal.sh --undo   re-enable them
#   add --dry-run to either to only show what it would do
# Nothing is deleted, and Opal Composer stays installed (C1 Tune reads its firmware and
# tuning files). The system-wide helpers need your password; the rest doesn't.
set -euo pipefail

undo=false dry=false
for arg in "$@"; do
  case "$arg" in
    --undo) undo=true ;;
    --dry-run) dry=true ;;
    *) echo "usage: $0 [--undo] [--dry-run]" >&2; exit 2 ;;
  esac
done

# run <command…>: run it, or just print it with --dry-run.
run() { if $dry; then echo "  would run: $*"; else "$@"; fi; }
# report <label>: say what happened to it.
report() { if $dry; then echo "would $($undo && echo enable || echo disable) $1"; else echo "$($undo && echo enabled || echo disabled) $1"; fi; }
uid="$(id -u)"

# Every com.opalcamera job launchd knows about in a domain, loaded or not, plus any whose
# plist is installed (so a job that has never run yet is caught too).
labels() {
  local domain="$1" dir="$2"
  {
    launchctl print "$domain" 2>/dev/null | grep -o 'com\.opalcamera[A-Za-z0-9._-]*'
    for plist in "$dir"/com.opalcamera.*.plist; do
      [ -e "$plist" ] && /usr/libexec/PlistBuddy -c 'Print :Label' "$plist"
    done
  } | sort -u
}

if ! $undo; then
  for app in "Opal Composer" Opal OpalLauncher; do
    pgrep -x "$app" >/dev/null && { run pkill -x "$app"; echo "$($dry && echo "would quit" || echo quit) $app"; }
  done
fi

# Per-user jobs: Opal's login items, start-on-USB-plug agent and virtual camera assistant.
for label in $(labels "gui/$uid" /Library/LaunchAgents); do
  if $undo; then
    run launchctl enable "gui/$uid/$label"
  else
    run launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    run launchctl disable "gui/$uid/$label"
  fi
  report "$label"
done

# System jobs: the camera-extension helpers (run as root) and the updater/uninstaller.
system_labels="$(labels system /Library/LaunchDaemons)"
if [ -n "$system_labels" ]; then
  $dry || echo "Opal's system helpers need your password:"
  for label in $system_labels; do
    if $undo; then
      run sudo launchctl enable "system/$label"
      plist="/Library/LaunchDaemons/$label.plist"
      [ -e "$plist" ] && { run sudo launchctl bootstrap system "$plist" 2>/dev/null || true; }
    else
      run sudo launchctl bootout "system/$label" 2>/dev/null || true
      run sudo launchctl disable "system/$label"
    fi
    report "$label"
  done
fi

if ! $undo && ! $dry; then
  echo
  echo "Done. Opal's virtual-camera system extension stays installed but idle: it only shows a"
  echo "camera while Opal Composer runs, and only Opal Composer can remove it."
fi
