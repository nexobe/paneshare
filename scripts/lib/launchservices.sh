# shellcheck shell=bash
# Sourced by make-app.sh and release.sh: keeps build copies of paneshare out of Spotlight,
# Launchpad and "Open With", so only the installed copy shows up. It also matters at run time: a
# pinned Dock helper and Sparkle find the main app by bundle ID through LaunchServices, and could
# otherwise pick a stale build.

LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

# Spotlight skips folders named *.noindex; .metadata_never_index covers older macOS releases.
hide_from_spotlight() {
  mkdir -p "$1"
  touch "$1/.metadata_never_index"
}

# Removes each given .app, and every .app under each given folder (nested ones too, such as
# Sparkle's Updater.app), from the LaunchServices database. Paths that no longer exist are still
# unregistered, so a vanished translocated copy is dropped as well.
unregister_apps() {
  [ -x "$LSREGISTER" ] || return 0
  local root app
  for root in "$@"; do
    [ -n "$root" ] || continue
    if [[ "$root" == *.app ]]; then "$LSREGISTER" -u "$root" >/dev/null 2>&1 || true; fi
    [ -d "$root" ] || continue
    while IFS= read -r -d '' app; do
      "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    done < <(find "$root" -mindepth 1 -name '*.app' -type d -print0 2>/dev/null)
  done
}
