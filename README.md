# oter

<img align="left" width="150" src="assets/oter.png" alt="oter">

A small GUI file manager with N panes, a command line and a shell. It looks like a text grid
and is built on [oket](https://github.com/ItsNotPaths/oket)'s pure packages.

Linux, x86_64.

```sh
curl -fsSL https://github.com/ItsNotPaths/oter/releases/latest/download/install.sh | sh
```

Or unpack the tarball and run it. Nothing is touched until you `:oter install`.

| | |
|---|---|
| `:oter status` | the mode, and every path it chose |
| `:oter install` | put the files where they go, then restart |
| `:oter uninstall` | take it all back out, config and places with it |
| `:oter update` | fetch the latest release and install it; then restart |

The same three run with no window as `oter --status`, `--install` and `--uninstall`.

Where the binary sits decides where its files go. In a `bin` directory oter is installed and
uses the XDG folders. Anywhere else it is portable: it reads config beside itself and never
writes defaults.

```
~/.local/bin/oter                                       the binary
~/.config/oter/{config.conf,binds.conf,places}          what you edit
~/.local/share/applications/oter.desktop                the launcher entry
~/.local/share/icons/hicolor/scalable/apps/oter.svg     its icon
```

## Getting around

Panes sit side by side. `y` marks, `shift+left` / `shift+right` copies the marks (or the cursor
item) to the pane on that side, and `ctrl+left` / `ctrl+right` moves them. `alt+left` /
`alt+right` changes focus. `tab` goes to the places sidebar, and `esc` comes back.

`alt+;` opens the command line. `alt+up` raises the shell drawer, `alt+down` lowers it.

## Places

`places` is one line per slot, numbered in the sidebar. A blank line is an empty slot, and a
line that is not a dir shows dimmed, so that is all a separator is. In the sidebar, `a` puts the
pane's dir in the slot, `s` puts a separator, `d` empties it, and `shift+up` / `shift+down`
move it. `enter` opens it in the pane you came from, and `1`–`9` open it in that pane.

## The command line

A bare line goes to the shell, `:` is a builtin, and `|` and `&&` chain them. A shell step on
its own runs in the drawer's shell, in the pane's dir. Its last line lands in the status line,
and the pane follows the shell's dir. A shell step inside a pipe is a filter.

```
:sel | grep jpg | :copy @+1     # only the marked jpgs, to the next pane
git status                      # last line in the status line
```

`@N` is pane N from the left, and `@+N` / `@-N` count from the focused one. `$o_src` is the item
under the cursor, `$o_dir` the pane's dir. An editor or any full-screen program takes the whole
drawer and gives it back when it exits.

## Binds

```conf
# binds.conf
[panes]
y           = :mark
e           = ${EDITOR:-vi} $o_src
shift+right = :sel | :copy @+1

[global]
ctrl+q      = :quit
```

Sections are `[global]`, `[panes]` and `[sidebar]`. A value is a command line, or `none` to
unbind. A row replaces the default for its chord, and a bad row is reported in the status line
with its line number while the rest still loads.

## Config

```conf
# config.conf
[launch] panes = 2            # panes open at launch
[theme]  name  = gruvbox      # helix TOML from themes/<name>.toml beside this file

[copy]                        # tried in order; the first whose program is installed runs
line = rsync -a --ignore-existing --info=progress2 -- $o_src $o_dir/
line = cp -aT --update=none -- $o_src $o_dst
```

A `[copy]` or `[move]` list in the file replaces the default list whole. A name clash skips the
item; nothing is overwritten.

## Build

```sh
./download-deps.sh               # oket, sdl3, stb, harfbuzz, libvterm into vendor/
./build.sh                       # debug, into build/
./release.sh --local             # stripped release, into build/
./release.sh --local --tarball   # and pack it into dist/
./build.sh test
```

Needs Odin and a C compiler. `build/oter` is portable, so it never touches an installed copy's
config.
