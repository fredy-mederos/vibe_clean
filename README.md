<img src="Resources/AppIcon-1024.png" width="80" alt="Vibe Clean icon" align="left" style="margin-right:16px" />

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)<br>[![Latest release](https://img.shields.io/github/v/release/fredy-mederos/vibe_clean)](https://github.com/fredy-mederos/vibe_clean/releases/latest)

<br clear="left"/>

# Vibe Clean

A small menu bar app that shows how much disk space is left, how fast it's shrinking, and lets
you pick developer junk to clean: Xcode DerivedData, Gradle caches, project `build/` and
`node_modules/` folders, merged git worktrees, old simulator runtimes, old IDE versions, package manager
caches, Docker data, plus your own large files and forgotten downloads.

Cleaning is always manual: nothing is deleted until you select it and confirm.

<p align="center">
  <img src="screenshots/vibe-clean.png" alt="Vibe Clean's menu bar window: free space, what can be cleaned by category, and the projects' build folders" width="400" />
</p>

## Download

**[Download VibeClean.dmg](https://github.com/fredy-mederos/vibe_clean/releases/latest/download/VibeClean.dmg)**
(the latest release, for macOS 14 or later on Apple silicon and Intel), open it and drag Vibe Clean into
Applications. Every version is on the [releases page](https://github.com/fredy-mederos/vibe_clean/releases).

Vibe Clean was called KeepMyMacClean until version 1.2.0. If you had it, move KeepMyMacClean to the Trash after
installing Vibe Clean: your settings and free-space history carry over (they stay in
`~/Library/Application Support/KeepMyMacClean`). Then check Settings → Open at login once.

It tells you when there's a new version: the bottom of the menu bar window shows the version and Check
for Updates, which turns into a green Update Available when GitHub has a newer release (it asks when
the app starts and once a day). Settings → Updates shows the same, with Download.

## Build and run

```bash
./scripts/build-app.sh --install   # builds "dist/Vibe Clean.app", copies it to ~/Applications, launches it
swift run KeepMyMacClean           # quick dev run (no notifications or login item outside a .app)
swift test                         # unit tests (use a fake home folder, never touch real files)
swift run kmmc scan                # read-only: print what the app would find
swift run kmmc discover            # read-only: show where your projects were found
swift run kmmc history             # read-only: free-space samples and the current trend
swift run kmmc digest [--sample]   # read-only: the weekly summary (needs 2 days of history; --sample fakes a week)
swift run kmmc projects            # read-only: stack, description and git activity of each project
swift run kmmc worktrees           # read-only: each git worktree, whether it's merged, and what's offered
```

The app icon is drawn in code: `swift scripts/make-icon.swift` writes `Resources/AppIcon.icns` (and a 1024 px
PNG preview), which `build-app.sh` copies into the bundle.

`build-app.sh` stamps each build: the version in `Resources/Info.plist` (`scripts/version.sh` prints or sets it),
the build number (commit count), the short commit hash (`+` when built with uncommitted changes) and the build
date. Settings → About shows them, the same rows as Vibe GitTree and Vibe Notepad.

Debug builds check for updates only when asked. `-CheckForUpdates YES` checks at launch as the released app does,
`-UpdateRepository owner/name` tries another repository's releases (one with a newer version shows Update
Available), and `-OpenMenuBarWindow YES` opens the menu bar window at launch:

```bash
CONFIG=debug scripts/build-app.sh
open -n "dist/Vibe Clean.app" --args -UpdateRepository fredy-mederos/devwispr -OpenMenuBarWindow YES
```

## Releasing

`scripts/release.sh` builds the app for Apple silicon and Intel, signs it with a Developer ID (with the hardened
runtime), packs it into `dist/VibeClean.dmg`, has Apple notarize it and staples the ticket:

```bash
APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_KEYCHAIN_PROFILE=<profile> scripts/release.sh
```

The `release-vibe-clean` skill (`skills/`, linked for Claude Code and Codex) runs a whole release: it picks and
confirms the version, builds the disk image, tags `vX.Y.Z` and publishes the GitHub release with notes from
`scripts/release-notes.sh`. Installed copies find it within a day.

On first launch the app walks your home folder for projects and remembers their parent folders
(`~/Documents/projects`, `~/AndroidStudioProjects`...). Edit them in Settings. macOS asks once for
access to Documents, Desktop and Downloads.

## How items are classified

| Kind | Meaning | Examples |
|---|---|---|
| Safe | The owning tool recreates it. Cost: a slower next build or a re-download. | DerivedData, project build folders, merged git worktrees, Gradle build cache, npm/pnpm caches, unavailable simulators, Remotion bundles and other temp-folder leftovers, browser caches, the current IDE's indexes |
| Review | Probably not needed, but worth a look. | iOS DeviceSupport, simulator runtimes, apps and data on a simulator, old Android Studio versions, Gradle dependencies, CocoaPods specs repo, older SDK platforms, unused Docker images and volumes, Codex and Claude Code conversations older than 30 days |
| My files | Your own files. Only ever moved to the Trash, with a suggestion for each. | Installers, archives already extracted, APK/IPA builds, videos, folders of smaller videos that add up (screen recordings), VM disks, ML models, old downloads |

Caches are deleted permanently (moving gigabytes of caches to the Trash frees nothing); your own files
go to the Trash.

Sizes are what deleting frees, not what `du` adds up: data a file shares with an APFS clone outside the item
doesn't count, so a worktree's copy of a video cloned from the main checkout shows as ~0, and files cloned
within an item count once.

Every item says why it's listed, what cleaning costs and what happens afterwards (the ⓘ button). Review
rows show the cost inline, colored by level:

| Cost level | Meaning | Examples |
|---|---|---|
| Rebuild | Recreated locally, next build is slower | DerivedData, Gradle build cache |
| Re-download | Fetched again from the network | Simulator runtimes ("~8.8 GB from Apple"), Gradle dependencies, SDK platforms |
| Lose an option | No data lost, but a possibility is gone | Toolbox rollback backups, old IDE settings |
| Data loss | Can't be recovered (red, and called out when confirming) | Emulators, Docker volumes and stopped containers, Xcode archives (dSYMs) |

Facts come from your projects where cheap: which Gradle version each project's wrapper uses, which API levels
they compile against, which Podfiles still use the git CocoaPods specs, how many simulators use a runtime.

Where a tool has its own cleanup command, the app uses it (`xcrun simctl delete unavailable`,
`xcrun simctl runtime delete`, `xcrun simctl erase`). Every path passes `PathGuard` before deletion: it must be
at least two levels inside your home folder and never one of the well-known folders. The one exception is what's
inside your own temp folder (`/var/folders/…/T`, below).

A project folder is only deleted when it passes two checks:

1. **It's a known build folder** in the place its tool puts it: `build/` next to `build.gradle(.kts)` or
   `pubspec.yaml`, `node_modules/` next to `package.json`, `Pods/` next to `Podfile`, `vendor/bundle/` with a
   `Gemfile`, NuGet `packages/` next to a `.sln`, Flutter's `ios/Flutter/*.framework`, Elixir `_build/` and
   `deps/`, `.venv/`, `dist/`, `.playwright-cli/` and so on (`ProjectArtifacts.rules`). Xcode DerivedData
   built with `xcodebuild -derivedDataPath` is found wherever it is and whatever it's called
   (`ios/build/DerivedData`), by what Xcode puts in it: an `info.plist` naming the workspace, `Build/`, and
   its logs or caches.
2. **Git ignores it** (the folder, or every file in it) **and nothing inside is tracked** (`GitIgnoreCheck`).

Git only ever removes folders from the list, never adds them, so gitignored app data (`data/`, `uploads/`,
`captures/`, `.env`) is never offered. Neither is a gitignored worktrees folder like `.claude/worktrees/`:
worktrees have their own category, below. Folders that fail the git check are kept and listed in the ⓘ
popover with the reason. Projects outside git can't be confirmed, so they're Review instead of Safe.
The ⓘ popover lists every folder that will be deleted.

## Git worktrees

Claude Code, Codex, Cursor and Conductor make a git worktree per task: a full checkout with its own
`node_modules/` and build outputs, so they add up fast. The app finds the worktrees of your repositories
wherever they are (`.claude/worktrees/` inside the repository, sibling folders) and the ones those apps keep in
their own folders (`~/.codex/worktrees`, `~/.cursor/worktrees`, `~/conductor/workspaces`, `~/.t3/worktrees`).

A worktree is offered whole only when removing it loses nothing:

1. **Everything committed in it is in the main branch** (origin's default branch, or `main`, `master`,
   `develop` or `trunk`, local or on origin). `git branch --merged` only sees merges and fast-forwards, so
   the content is compared too, which catches GitHub's rebase and squash merges. Any of these counts:
   its commit is in main's history; main has the same version of every file it changed; every commit has a
   twin in main with the same changes (patch ids without context lines, because after a rebase the lines
   around a change often differ and `git cherry` misses it); or one commit in main has all its changes
   together (a squash merge).
2. **Nothing is uncommitted**: no modified, staged or untracked files. Ignored build outputs don't count.
3. **It isn't locked** (`git worktree lock`) and has no submodules, which `git worktree remove` won't take.

It's removed with `git worktree remove`, after checking it's still on the commit that was scanned; git itself
refuses if any file changed since. The branch stays.

A merged worktree is only Safe when nothing else is lost with it either. It's Review when:

- **It has git-ignored files of its own**: renders, captures, screenshots attached to a PR. Ignored files in
  build output, cache and editor folders (`build/`, `node_modules/`, `.idea/`, DerivedData...) don't count, and
  neither do files the main checkout has too, byte for byte (apps copy `.env` and the like into new
  worktrees; APFS clones are recognized without reading them). Nor do the `local.properties` Android Studio
  writes with only the SDK's location, ignored lock files, or `.DS_Store`. The row says how many and the ⓘ
  names the biggest.
- **Something has it open right now**: a terminal, a Claude Code session, an editor, a running build (one
  `lsof -n -P` pass over your processes, a fraction of a second). The `adb` server, which keeps the folder it
  was started from until you restart, doesn't count.
- **It was used in the last 2 days**, since a session or editor may still come back to it. "Used" means its
  last commit or checkout, or the latest edit to a file that's still uncommitted. Not the index: every
  `git status` from an editor or git app rewrites it, and a Mac you just moved to would otherwise show every
  worktree as used today.

Worktrees are listed by last use, longest ago first, and each row says when ("used 3 months ago"; hover for
the date). With worktrees of more than one repository, they're grouped by repository: each group's row shows
how many there are, their size and when any of them was last used, its checkbox selects them all, and tapping
it folds them away. The repository whose worktrees were all used longest ago comes first. Project build folders
are listed by last use too.

`kmmc worktrees [text]` shows all of this per worktree, for the worktrees whose path contains `text`.

Other worktrees stay. Their gitignored build folders are offered instead, with the same checks as a project,
and the row says what keeps the worktree ("2 uncommitted changes, 1 commit not in main"). Project build
folders skips linked worktrees, so nothing is listed twice.

## Smarter suggestions (optional)

With Settings → Suggestions → "Smarter suggestions (on-device AI)" on (macOS 26+ with Apple Intelligence),
Apple's on-device Foundation Models write a one-line suggestion for each of your own files from its name, type,
folder, size and dates. Suggestions are generated when a row appears, cached in
`~/Library/Application Support/KeepMyMacClean/suggestions.json`, and fall back to the fixed text. The model
only writes text; it never changes what an item is or what cleaning does. Nothing leaves your Mac.

Project rows show what each project is. The app reads the stack (Next.js, Flutter, Android…), the project's own
description (package.json, pubspec.yaml or the README's first paragraph, skipping template text and bare links)
and git activity. With Smarter suggestions on, the model condenses descriptions that are long or not in English
("React escape room prototype inspired by Rusty Lake games"); it never sees dates, so it can't misjudge activity.
Without a description the line is built from the stack and latest commit, because in testing the model only
guessed from the folder name. `swift run kmmc projects` lists what the app knows about each project.

## Free space history

The app samples free space every 30 minutes while it runs and keeps 90 days in
`~/Library/Application Support/KeepMyMacClean/history.json`. The trend ("−2 GB/day · full in ~14 days")
uses the last 7 days and ignores jumps up from cleanups, so cleaning doesn't hide how fast the disk fills.
A full scan runs every 6 hours; categories that grew more than 500 MB in about a week show it.
A notification fires when free space drops below your threshold, or when the current pace fills the disk within a week.

Once there are 2 days of history, the popover shows a summary card ("Free space down 9 GB this week. Xcode and
simulators grew 6.1 GB, mostly Acme build data…") with a shortcut that selects the item that grew the most. With
a full week of history it's also sent as a weekly notification (Settings → Alerts). `swift run kmmc digest`
prints it; `--sample` shows a made-up week.

The summary is written by the app, not a language model: in testing, Apple's on-device model reworded it
accurately but kept dropping the most useful details (which item grew, the pace, what you cleaned).

## Temporary files

Your temp folder (`$TMPDIR`, `/var/folders/…/T`) is where command-line tools work, and some never clean up.
Remotion's `bundle()` copies the whole project, `public/` folder included, for every render; Instruments
leaves raw recordings; Xcode leaves export folders. The app groups these by tool (Safe, with what to quit
first) and lists any other temp file or folder of 100 MB or more that nothing changed for 3 days (Review).
Leftovers changed in the last hour are left out, since a render may still be using them, and so is Apple's
own (`com.apple.*`).

To stop Remotion bundles piling up, delete the folder `bundle()` returns once the render is done and pass
`symlinkPublicDir: true` so `public/` isn't copied each time.

## Layout

- `Sources/CleanerCore`: scanning, sizing, project discovery, cleaning. No UI.
  - `Scanners/`: one scanner per category. Scanners list items quickly and return probes; `ScanEngine`
    measures probes in parallel and streams results.
- `Sources/KeepMyMacClean`: SwiftUI `MenuBarExtra` app (the code keeps the app's first name), with its version info
  and update checks (`UpdateCheck.swift` is the same file in Vibe GitTree and Vibe Notepad).
- `Sources/kmmc`: read-only CLI.
- `Tests/CleanerCoreTests`: Swift Testing suite.
- `Tests/KeepMyMacCleanTests`: the update check's version comparison and GitHub parsing.

## Roadmap

1. ✅ Menu bar free space, dev cleaners (safe + review), project discovery, low-space alert, open at login
2. ✅ One-click selection of inactive projects and DerivedData, older Android SDK platforms/sources/build tools, Docker (`docker system df` + prune)
3. ✅ Large files and downloads with suggestions (Trash only), free-space history, trend and "days until full", category growth, redesigned popover
4. ✅ Cost of cleaning on every item (reason, cost level, ⓘ details, data-loss warning), optional on-device AI suggestions, build version in Settings
5. ✅ Weekly summary of what changed, with a shortcut to the biggest grower
6. ✅ Project one-liners: stack, description and git activity, condensed on-device when long or not in English
7. Explaining unknown big folders (curated list + optional cloud model)
8. Treemap explorer, Full Disk Access view of hidden space (Trash, Photos, device backups)

## License

MIT, see [LICENSE](LICENSE).
