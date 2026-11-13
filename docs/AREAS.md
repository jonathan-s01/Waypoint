# Areas: quick navigation in any window (Waypoint)

Added 14 Nov 2026. No recipe needed; a recipe's own parts (`PanesAppModule`) still win in the apps that have one.

## Keys (all remappable in the keyboard commands editor)

| Key | What it does |
| --- | --- |
| Right Option 0 | The Global area, as a list: the app's own bars (rails, top strips) and every toolbar button |
| Right Option 1 to 9 | The panes and big bands, in layout order (top row first, left to right); the side panel is always last |
| TurnOver Option O | Tools: the controls of the area you are in, as a menu. Pressed again in the list: the Global tools, and back |
| TurnOver Option M | Main content: the biggest pane, whatever view the app is showing |
| TurnOver Option A | Navigation: the first list (sidebar, chats, mailboxes) |
| TurnOver Option F | The window's search field |

Right Option and a number on a **tool area** (Global, a band such as Excel's ribbon, a side panel such as Numbers' formatter)
opens its tools as a list, so arrows, Return and Escape work whatever the app does with them. On a list, table, page or
text area it puts the focus there, and the app's own keys apply.

The Tools list is a persistent panel (`AreaPanel.swift`): it stays open after a press and re-reads the area, keeping
your place by label. Left and Right move between groups (`AreaMap.groups`: the tabs first, then each cluster, then
"Other"); Up and Down move within a group. Pressing a tab switches to it and lands on the first cluster. Letters jump by
first letter, TurnOver F searches, Escape closes and leaves the focus where it was. Each control reads with its value.
- Slider or stepper: Return starts adjust mode (Up/Down or Left/Right step it; Return or Escape ends).
- Text field or combo: Return starts typed entry (Return sets the value, Escape cancels). A search field hands the focus over.
- Pop-up or menu button: the menu's choices open as a sub-list (Right opens it, Left goes back). Excel's split buttons
  only do their default action: their menu needs Control-Option-Shift-M, not yet sent.
- A dialog or popover taking the window closes the panel. TurnOver Option O in the panel toggles the area and Global.

## How areas are found (`AreaMap.swift`, pure and tested; `AreaMenu.swift`, the walk and the keys)

- The window is read level by level (shallow first) with a 2.5 s and 8000 element limit, so chrome that comes late in an
  app's tree (Mail's toolbar, after its message pages) is found; what is cut is the depth of a page. The log line
  `areas:` says how many elements, whether it was cut short, and the areas found.
- Recomputed on every key press, never cached, so a pane that comes or goes (an inspector, Messages' details) is
  simply there or not. A sheet or dialog on the window is the only area while it is up.
- Panes: lists, tables, pages, text areas, scroll areas and large named groups. The outermost wins, unless it holds
  panes side by side (a web app's one big page). A pane that runs under its neighbours is cut back.
- A toolbar is never an area: each button goes to the pane whose column it sits over. Global lists them all too.
- Inside a pane only toolbars and clusters of buttons (sheet tabs, a message's actions) are tools; controls in rows are not.
- A band of 12 or more controls that is not a toolbar (Excel's ribbon, VS Code's status bar) is its own area. Narrow
  full-height rails go to Global. A column at the right edge (12 to 35% of the window, 3 or more controls) is the side panel.
- A page and nothing else (a browser): everything outside the page is Global.

## The second reader (review layer)

The review layer is a second copy of the same commands, aimed at what it reads rather than at the keyboard focus. The
area commands share one implementation (`AreaMenu.command`); a `second` flag says who they are for, and in that mode
nothing takes the keyboard focus (a jump places the review cursor, a press is an AX press, a field is set by typing in
the panel).

Left Option and Right Option never share a meaning:

| Keys | Meaning |
| --- | --- |
| VO + Left Option + O, M, A, F | tools, main, navigation, search, for the keyboard |
| VO + Right Option + O, M, A, F | the same, for the second reader |
| Right Option + 0 to 9 | area jump for the keyboard |
| Chord (Left Option + Right Shift) + Right Option + 0 to 9 | area jump for the second reader |
| Chord + Right Option + arrows | review by word (the only place Right Option means "by word") |
| VO + Option + Command + Shift + / | the second reader goes back to following the keyboard |

After a jump the second reader stays in that window, even when the keyboard moves or another app is in front, until the
reset key. Without a jump it follows the focus as before. The chord's hold keys cannot include Right Option (the
capture refuses). A chord with other keys still works; the area jump is the chord's hold keys + Right Option + a digit.

In a web page the second reader has its own copy of the browse document (`ReviewLayer.ownCopy`), so the two readers
keep separate places. A copy is not the page's remembered place, hears nothing of the page changing, and is read again
after a pause. The reset key is changed with the command "Chooses the key that puts the second reader back with the
keyboard"; it also gives up the standard key. "Puts the review layer's keys back" restores the standard one.

Clicking with VO (or the chord's keys, or VO + Right Option) puts the keyboard's reader (or the second reader) at the
pointer; the second reader's click never moves the keyboard's focus.

Not known yet: whether macOS lets the second reader read a full-screen window on another space (it is expected to
work only while that window is visible to accessibility); if not, the per-window position is the fallback.

## Not done yet

- Mail's reading area shows only the latest message when jumped to; the cause is not yet known.
- Moving through the controls of a tool area by arrows without a list (an inline mode) is not done; the list is it.

- Announcing "side panel opened" or "closed" without a key press.
- Teams' and GitHub Copilot's recipes are still in place: Right Option 1 to 9 go to the recipe's parts there (Control
  Command 1 to 9 too), and Right Option 0 is still the generic Global list. Trial the generic areas in Teams before
  slimming the recipe.
- Heard-by-ear checks in every app: the tests use synthetic windows with the geometry seen in Messages, Notes, Excel
  and a browser.
