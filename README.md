# Gitunia

Gitunia is a macOS git client for keeping an eye on a lot of repositories at once. I built it
because I kept running AI agents across a dozen repos at the same time, and every git client I
tried assumed I had one repository open and had written the changes myself. Neither was true
anymore.

So in Gitunia you build a workspace out of repositories and whole folders of them (repos that
show up in a folder later join on their own), and see them all in one window: which ones moved,
what changed, what is waiting to be pushed. It updates on its own as files change on
disk. What it doesn't do is write anything behind your back. No auto-commit, no auto-push, no
agent holding the keys. Reviewing is the point, and the decisions stay with you.

## Install

Grab the latest `.dmg` from the [Releases page](../../releases/latest), open it and drag Gitunia
into Applications. The build is universal, so it runs natively on Apple silicon and Intel.

The app isn't notarized (that needs a paid Apple developer account), so macOS will refuse to open
it the first time. Either right-click the app, choose Open, then Open again, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Gitunia.app
```

Gitunia updates itself. Once a day it checks GitHub for a newer release, downloads it in the
background, checks its signature, and asks you to restart; quitting installs it too. That needs
the app to live somewhere it can write to, like /Applications. Gitunia → Check for Updates…
checks right away, and Settings → Updates turns either part off.

You need macOS 15 or newer and `git` on your PATH. If you want commit messages drafted for you,
install the [Claude Code](https://claude.com/claude-code) CLI or [Ollama](https://ollama.com).
Both are optional.

## Getting started

Gitunia works with workspaces, much like VS Code. A new window starts as an untitled workspace.
Add Repos in Folder (File menu or ⌘K) links a folder: every repository in it, up to three levels
deep, joins the workspace, and so does any repository that shows up there later. Add Folder to
Workspace adds a single repository. Save Workspace As writes the list to a `.gitunia-workspace`
file you can open again with ⌘O, and each window can hold a different workspace. Quit with two
windows open and both come back next time.

Gitunia keeps its own files (settings, per-repo preferences, the activity log and untitled
workspaces) in `~/Documents/Gitunia`, a plain folder that is safe to sync or back up. Older installs
kept them in `~/Library/Application Support/Gitunia`; they are moved over automatically on first launch.

The sidebar shows every repository in the workspace with its current branch, ahead/behind counts
and a badge for uncommitted changes. From there:

- Click a repository to see its changes. Click a file to see the diff.
- Hover a repository in the sidebar to pull or push it without switching to it.
- Press ⌘K for the command palette. Almost everything in the app can be reached from there by
  name, including actions on repositories you don't have selected.

## What it can do

The short version: it covers the git you use day to day, and it's careful about the parts that
can lose work.

**Seeing changes.** Diffs can be inline or side by side, as hunks or as the whole file, with
word-level highlighting and long unchanged stretches folded away. The file list works as a flat
list or a tree. You can stage single hunks or just the lines you select, and discard the same way.

**Committing.** Normal commits, amending the last one, undoing it (a soft reset, so nothing is
lost), stashing all or some files. There's an optional button that asks Claude or a local Ollama
model to draft the message. Any repository can be marked "local AI only", which keeps it away from
cloud models entirely.

**History.** Browse any branch, filter by text, `author:`, `path:`, `since:` and `until:`. Revert,
cherry-pick, check out, tag, branch from or reset to any commit. File history follows renames and
lets you restore an old version. Blame is a toggle in the diff toolbar, and clicking a line takes
you to the commit that wrote it.

**Compare.** Puts your branch next to its base and shows the commits it adds and the combined diff.
Handy for "what did this agent actually do on its branch".

**Branches, tags, remotes.** Checkout, merge, rebase onto, rename and delete from the branch menu
in the toolbar (click a branch to check it out, hover it for everything else). Tags, remotes,
upstreams, cleaning up merged branches, clone, new repository, submodules and worktrees are all
there too. Worktrees that agents put inside a repo, like `.claude/worktrees/<name>`, show up as
repositories of their own.

**Not losing work.** This is where most of the care went. Gitunia warns before git would complain,
for example when switching branches with uncommitted changes, and offers "stash and switch". A
pull where both sides moved asks whether to rebase or merge instead of picking for you. Reset
explains what soft, mixed and hard would each do in this repo before you choose. Deleting
untracked files shows the exact list first and deletes only that list. The reflog is one click
away, so a commit lost to a bad reset can be brought back. Force push exists, but only as
`--force-with-lease`, for one branch at a time, and only after you confirm the branch and remote
by name.

**Conflicts.** A merge, rebase, cherry-pick or revert that stops on conflicts gets its own section
and a banner with Continue, Skip and Abort. During a rebase the "mine/theirs" buttons are labelled
for what they actually mean there, since git swaps the two sides.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘N | New window |
| ⌘O | Open a workspace |
| ⌘⇧S | Save workspace as |
| ⌘R | Refresh all repositories |
| ⌘K | Command palette |
| ⌘⇧F / ⌘⇧L / ⌘⇧P | Fetch / pull / push the selected repository |
| ⌘↩ | Commit |
| ⌘⇧O | Open the current file in your editor |
| `s` / `u` | Stage / unstage the selected files, or the selected lines in the diff |
| `j` / `k` | Next / previous change in the diff |
| Esc | Clear the line selection |

Settings (⌘,) cover appearance, how often to fetch in the background, which editor to open files
in, and which AI provider to use.

## Building from source

It's a plain Swift package, no Xcode project needed. You'll want Xcode 26 or a Swift 6 toolchain.

```bash
swift run Gitunia
```

To run the tests:

```bash
swift test
```

To build the app bundle or a DMG into `dist/`:

```bash
scripts/build-app.sh
```

```bash
VERSION=0.2.0 UNIVERSAL=1 scripts/make-dmg.sh
```

`UNIVERSAL=1` builds for both Apple silicon and Intel. Leave it off for a faster local build.

The code is split in two. `Sources/GituniaCore` holds the git runner, parsers, models and stores,
without any SwiftUI, and has most of the unit tests. `Sources/Gitunia` is the SwiftUI app on top.

## Contributing

Issues and pull requests are welcome. If you're planning something bigger, open an issue first so
we can talk it through before you put the time in. One rule worth knowing up front: Gitunia never
commits or pushes without the user asking, so changes that automate writes won't be merged.

## License

MIT. See [LICENSE](LICENSE).
