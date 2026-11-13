# Waypoint's interaction model

How Waypoint is meant to be used, and how much of it exists. Checked against the code on 13 Nov 2026. The original
plan (v0.3, then v0.6 of 9 to 10 Nov 2026) was a written document kept outside the repository; this file replaces it
as the record of what is built. Where the two disagree, the code and this file win.

Related: [AREAS.md](AREAS.md) (areas and the second reader in detail), [the guides](../Guides/index.md) (what a user
reads), [WAYPOINT.md](../WAYPOINT.md) (how the fork is run).

## The idea

A screen is two-dimensional; speech is one line. Waypoint presents each app as a few named regions, remembers where you
were in each, and gives the same few keys in every app.

1. **Where**: jump straight to a region, landing where you were.
2. **Here**: the kind of region decides what the plain keys do (a list: Up and Down; a document: arrows read it; a text
   field: keys go to the app). No mode is chosen by hand, and a mode changes only when you move to another region, never
   because of a focus event you did not cause.
3. **Do**: one key lists everything that can be done to the item you are on.
4. **Anywhere**: one list finds an app, a menu command, an action or a Waypoint command and runs it.

Principles that still stand: never lose the user's place; instant responses (anything slow must never block speech);
the same keys in every app; every key can be remapped and every feature turned off; local and private by default;
predictable behaviour from saved rules rather than AI guesses.

## Status

| Part | State | Where |
| --- | --- | --- |
| Focus memory (app and region, kept a week, survives restarts) | Built | `FocusMemory*.swift` |
| Areas: jump to any window area without a recipe, and the Tools list | Built | `AreaMap`, `AreaMenu`, `AreaPanel` |
| Second reader (review layer): read around a text field without leaving it | Built | `ReviewLayer*.swift`, `ReadWhileTyping.swift` |
| Skim: a list by key words, fast | Built (one item per key press; no auto-advance) | `SkimMode`, `SkimText` |
| Important words first, outside skim | Not built (only inside skim) | |
| What changed in a region since you left it | Built | `WhatChanged.swift` |
| Describe this app | Built | `DescribeApp.swift` |
| Item actions menu | Built | `ItemActions.swift` |
| First-letter jump in any list | Built | `LetterJump.swift` |
| Places: bookmarks and recent places | Built | `Places*.swift` |
| Anywhere: apps, menus, item actions, window parts, Waypoint commands | Built, no language model | `System/Anywhere*.swift`, `System/MenuBarList.swift` |
| Launcher: Right Command + key opens apps, runs commands | Built | `Launcher*.swift` |
| Mouse and pointer reading | Built; off by default | `MouseTracking`, `PointerReader`, `PointerPlace` |
| Teams and GitHub Copilot recipes (panes, messages read as documents) | Built; the generic areas are not yet trialled in Teams | `Resources/recipes/` |
| The region type picks the plain keys, for any app | Partly: only where a recipe marks a part as a document | |
| Command layer with a local language model (plan 4.11, 4.12) | Not built; a plan exists | |
| Customize any app in place: rename, hide, pin, make a region (plan 4.17) | Not built | |
| Read the latest message or response in the app, from anywhere (plan: SR+L) | Not built | |
| A sound for each mode | Not built (see below) | |
| Spatial audio, magnification sync, task views | Not built | |

## The keys as built

"VO" is the TurnOver key (Caps Lock or whichever you chose). All are remappable; category Waypoint in the key list.

| Keys | What it does |
| --- | --- |
| Right Option 1 to 9 | Jump to a pane or band of the window, in layout order; the side panel is last |
| Right Option 0 | The Global area: the app's bars and every toolbar button, as a list |
| VO-Option-O, M, A, F | Tools of this area; main content; first list (navigation); the window's search field |
| Left Option + Right Shift, then a key | Second reader: read around the field. VO-Option-R arms it; VO-Option-S, Q, I, Y then say, quote, insert or copy |
| VO-Option-N | Skim on or off in a list; Return reads the item in full |
| VO-Option-B, G, P | Bookmark here; open bookmarks; recent places |
| VO-Command-Space | The item's actions |
| VO-Command-A | Anywhere |
| Control-Command-W | What changed here; twice, in the whole app |
| Control-Command-0 | Describe this app; twice, as a list to move to a part |
| Right Command + letter | Launcher; with Right Option too, the second layer |
| Letters in a list | First-letter jump |

### Replaced: the plan's key scheme

The plan proposed the TurnOver key plus a number for regions, with Return for the command bar, K for skim, W for what
changed, B for bookmarks, E for customize, L for the latest message and J to jump to a region by name. The code went
another way: Right Option for areas, VO-Option letters for the reading tools, VO-Command for actions and Anywhere,
Control-Command for what changed and describe, Right Command for the launcher. The table above is the scheme in use,
and the plan's keys are not used. The features the plan gave keys to that are still not built (customize, latest
message) have no key yet.

## Sounds

Only skim has any: a rising two-tone when it starts, a falling one when it ends, and a tick between items. The old plan
said a short sound marks each mode; that was never built. The review layer, the Areas Tools list and the launcher make
no sound when they start or stop.

**Proposal, not decided:** give each mode one short two-tone in the style of skim's, so the pitch pair tells you which
mode you entered, with the falling version for leaving. Keep them quiet (skim uses volume 0.15), put them behind one
setting so they can be turned off, and add them in the owning file with `Tones.beep`, as `SkimMode.tone(on:)` does.
To settle first: which modes get one (review layer, Tools list, launcher layer 2), and whether the sound sits before
or after the spoken word.

## Open questions

- Held modifier or toggle for the second reader: both exist (chord, and VO-Option-R once or twice).
- Skim: auto-advance (the plan) or one item per key (built). Which, and at what rate?
- How personal changes layer over shared profiles, when customize mode exists.
- Whether spatial audio is worth an experiment.
- The project's name, and whether it gets its own bundle identifier (today it keeps TurnOver Developer's, so granted
  permissions carry over).
- Still to do by ear: the generic areas in Teams, then slimming the Teams and GitHub Copilot recipes (AREAS.md).
