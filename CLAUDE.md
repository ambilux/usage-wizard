# usage-wizard — Claude Code usage tools (macOS)

- `build.py`: `python3 build.py` → regenerates `dashboard.html` (generated output, don't hand-edit).
- `menubar/`: Usage Wizard menu bar app (Swift, no Xcode). Build + install + relaunch only via `menubar/build.sh` (installs to /Applications). Keep `-swift-version 5`, target arm64 macOS 14.
- App icon + menu bar icons (wizard, hat, wand): drawn by `menubar/icon/make_wizard.swift` during `build.sh`; no image files in the repo except `docs/banner.svg` (README banner, `--banner` mode of the same script) and the README screenshots in `docs/` (dark mode, example data only, rendered with `TZ=UTC`, converted to plain sRGB without metadata).
- No test suite; verify by running the app (`pgrep -lf UsageWizard`) or opening the dashboard.

## Constraints (decided, don't reopen)
- Local only: no network, no third-party packages. Read only `~/.claude/projects`; write only `.handoffs/`.
- No auto-paste, no Accessibility permission, no CGEvent/AX APIs; ad-hoc signing only (no certificates).
- Privacy: keep only minimal log data in memory (see `Store.swift`: only prompts containing `.handoffs/`, replies as a Bool).
- Handoff flow is 2 steps (write `.handoffs/<timestamp>_….md`, open new chat via `claude://code/new?folder=…&q=…`); used handoffs go to Trash.
- UI text in English.
- System/security settings (TCC, keychain) are changed by the user, never by Claude.
