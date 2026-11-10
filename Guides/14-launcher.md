# The launcher

The launcher runs an action from a key you hold: open an app, bring it forward, run a shell command, open a web page or
a file, or run any Waypoint command. It is on by default.

## How it works

- Hold **Right Command** and press a letter: that letter's action runs, and the key is not typed or passed to the app.
  This is **layer 1**.
- Hold **Right Command and Right Option** and press a key: **layer 2**, a separate table that starts empty. It never
  also runs layer 1's key.
- A key with no binding, and Right Command held with any other modifier (Shift, Control, Left Option, Left Command),
  goes through to the app untouched. Right Command alone behaves as it always did.
- When Waypoint has handed over to VoiceOver, the launcher does nothing.

Opening an app: it launches if it isn't running, comes forward if it is, and if it is already in front, the next window
comes forward. Waypoint says "Opening Google Chrome" or just the app's name. An app that isn't installed is announced
as "not installed".

## The keys that come with it (layer 1)

G Google Chrome, H GitHub Copilot, O Microsoft Outlook, M Microsoft Teams, S Safari, F Finder, I Messages,
X Microsoft Excel, Z Terminal, C Colour Contrast Analyser, T TextEdit.

**These take over from the usual shortcuts.** Right Command with C, X, Z, S, F, T, H or M used to be Copy, Cut, Undo,
Save, Find, New Tab, Hide or Minimise. Left Command still does all of those. Delete or change a binding to get a
shortcut back.

## Changing it

- **Settings, Launcher**: a list per layer with Add, Edit and Delete, a key field, the held keys, and Reset to
  defaults. Everything in it works from the keyboard and with a screen reader.
- **The file**: `~/Library/Application Support/TurnOver/launcher.json`. It is plain JSON you can edit by hand. Waypoint
  picks up a change by itself; the command **launcherReload** reads it at once.
- **Held keys**: the commands **launcherSetHold1** and **launcherSetHold2** wait for you to press the keys you want
  held, **launcherResetKeys** puts back Right Command and Right Command with Right Option, and **launcherEnable**
  switches the launcher on or off. **launcherList** lists the bindings; choose one to run it.

## The file

```json
{
  "version": 1,
  "layer1": [
    {"key": "g", "kind": "app", "name": "Google Chrome", "bundle": "com.google.Chrome"},
    {"key": "u", "kind": "open", "name": "Docs", "target": "https://example.com"},
    {"key": "d", "kind": "shell", "name": "Backup", "target": "~/bin/backup.sh", "timeout": 60},
    {"key": "l", "kind": "command", "target": "launcherList"}
  ],
  "layer2": []
}
```

- `kind` is `app`, `shell`, `open` or `command`.
- **app**: `bundle` (the identifier) and/or `name`. Either is enough; the name is looked for in the running apps and the
  Applications folders.
- **shell**: `target` is run with `/bin/zsh -c` in your home folder, in the background, and stopped after `timeout`
  seconds (30 if missing, 300 at most). Its output is thrown away. If it fails, Waypoint says so.
- **open**: `target` is a web address or a file or folder path (a leading `~` is your home folder).
- **command**: `target` is the name of a Waypoint command, as in the key lists.
- `key` is a letter, a digit, or a key name from the key lists, such as `upArrow` or `f5`.
- Unknown fields are kept out of the way, and an entry that can't work is skipped and logged; the rest load.

A file that can't be read at all is logged and copied next to itself as `launcher.json.corrupt-` and the date; the
built-in keys are used and your file is left alone. Whenever Waypoint saves, the file it replaces is kept as
`launcher.json.bak`.

## Limits

- Cycling windows brings the back window of the app forward. For an app that lists its windows in a fixed order, two
  windows may swap places rather than rotate.
- Repeating a held key doesn't run the action again.
