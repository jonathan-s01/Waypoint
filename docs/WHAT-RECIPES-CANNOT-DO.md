# What a panes recipe cannot do

Written 12 Nov 2026 from the Teams, GitHub Copilot, Discord and Notes recipes (`Resources/recipes/`). A recipe is data: a
list of named parts, each found by an `ElementMatch` (`Sources/Core/Plugins/Profiles.swift`), with an optional hint, an
optional `"read": "document"` and an optional `land` match. It names where things are. It does not decide what they do.

## What a recipe can do

- Name the regions of a window and give Tab, Shift-Tab and Control-Command-1 to 9 a stable order.
- Match a part by role, subrole, identifier, title, description, help, value, text, window title, ancestor or parent, or by
  `any` of several matches.
- Say how a part behaves: a text field takes the keyboard, a list is held by the cursor, a `document` part is read as text.
- Say where a document part lands (`land`), by default on its last heading.

## What it cannot do

1. **Find what the app does not expose.** A part with no role, label or identifier that tells it apart from its
   neighbours cannot be matched. Apps that draw their own UI (some Electron canvases, games) have nothing to match.
2. **Survive label changes.** Matching by description or text breaks when the app renames or translates a label. Prefer
   `identifier`; Teams has few, so its recipe leans on descriptions.
3. **Match by position or by what is on screen.** There is no "the second toolbar", "the button left of Send" or
   "the blue one". `nth` picks among matches in tree order only.
4. **Run code or react to events.** A recipe cannot say "when a message arrives, say it", "after Send, move here" or "if
   this panel is open, do X". Event handling, new keys and app-specific speech need a plugin with a script, or a Swift
   module (`MODULE-GUIDE.md`).
5. **Change what a key does inside a part.** Arrows, Return, Escape and typing keep the part's normal behaviour. A recipe
   chooses the mode (keyboard, held list, document); it cannot remap keys within it.
6. **Read the content differently.** Message grouping, which text to say first, skipping timestamps or reaction rows:
   a document part reads what the accessibility tree gives. Reshaping needs a profile's rules or code.
7. **Handle parts that come and go.** A part is looked up in a bounded search (about 0.8 s) and cached for ten seconds.
   Panels that appear for a moment, or that move when the window is resized, may be missed or found late. A missing part is
   skipped, not waited for.
8. **Reach outside the window.** Menus, popovers, sheets and other windows are not parts of the window. Menus and the
   actions menu work everywhere; the rest have no recipe support.
9. **Depend on state.** One list of parts applies whatever the app is showing. It cannot differ between Chat and Calendar
   in Teams; a part that does not exist in the current view is skipped.
10. **Persist or remember anything.** Focus memory, places and the review layer work on any recipe app, but a recipe does
    not configure them.

## When to leave recipes

- A behaviour that needs to react to something: a plugin script.
- Behaviour many apps share: a building block in Core (`docs/BUILDING-BLOCKS.md`).
- An app so unlabelled that nothing can be matched: report it to the app's developer; it will not work for any screen
  reader.
