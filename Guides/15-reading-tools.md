# Reading tools

These Waypoint features help you move through busy apps quickly. Each can be switched off, and every key can be changed in
the key list. "VO" below means the TurnOver key (Caps Lock or whichever you chose).

## Skim: hear a list quickly

Use it in a list of messages, files or results.

1. Press **VO-Option-N**. Waypoint says "skim on" and how many items there are.
2. **Up** and **Down** now say each item's key words only, fast, with a tick between items. The speech rate returns to
   normal a moment after the last item.
3. **Return** says the item in full and leaves the cursor on it, and skimming ends.
4. **Escape** or **VO-Option-N** again ends it without choosing.

Skim ends by itself when the focus moves to something else, you switch apps, a menu opens or you leave it alone for five
minutes. Nothing plays by itself. If it says "skim is off", run the **skimEnable** command.

## Review layer: read around while you type

In a text field, such as a chat box, you can read the page or window without leaving the field and without typing
anything. The layer is on by default.

1. Hold **Left Option + Right Shift** and press a key. Each press is one step and the field keeps the keyboard.
   Or tap **VO-Option-R**, then press the key; tap it twice to keep the layer on until you press it again. **Escape** ends
   it.
2. Keys: letters are browse-mode quick keys (**H** next heading, with **Left Shift** added, previous); **Up** and **Down**
   read by line, **Left** and **Right** by character, **Right Option** with them by word; **Home**, **End** and the
   **Page** keys jump; **Tab** goes to the next link or control (**Left Shift** for the previous), in the review only,
   and never moves the real focus; **Return** presses what is under the cursor. Quick keys do not wrap round the page.
   From a chat's message box the review starts at the latest message. It keeps its place while you type; it moves to a
   message only when a new one arrives, and says "new message".
3. **Left Shift** with the chord and an arrow selects text in the field (with **Right Option**, by word).
4. Afterwards, for five minutes: **VO-Option-S** says where the review cursor is, **VO-Option-Q** puts the reviewed text
   into the field as a quote, **VO-Option-I** inserts it as it is, and **VO-Option-Y** copies it.

Passwords and read-only fields are refused. **VO-Shift-F5** and a click with the TurnOver key held (no click reaches the
app) put the review position where the mouse pointer is.

## Places: bookmarks and recent places

- **VO-Option-B** bookmarks the current item, named from its text.
- **VO-Option-G** opens your bookmarks: type part of a name and press Return to go there.
- **VO-Option-P** lists recent places, newest first.

Bookmarks are saved in `places.json` in Waypoint's support folder. The command **placesDelete** removes one.

## Focus memory: return to where you were

- Switching away from an app and back puts the focus where you left it, if the app has not already done so itself.
- In apps with named regions (Teams, GitHub Copilot, Notes), moving to another region and back lands on the item you were
  on and says so. In a message region it lands on the newest message if one has arrived, and says "newest".
- It is kept across restarts for a week, as short fingerprints (roles and up to 80 characters of text), in
  `focus-memory.json`. **focusMemoryPersist** turns that off and **focusMemoryForget** empties it.

## Areas: jump to a part of any window

- **Right Option 1** to **9** go to the window's panes and bands, in layout order; the side panel is last.
- **Right Option 0** lists the app's bars and every toolbar button. On a tool area (a ribbon, a formatter) the digit opens
  its controls as a list; on a list, table or page it puts the focus there.
- **VO-Option-O** lists the controls of the area you are in (twice, the global ones). **VO-Option-M** goes to the main
  content, **VO-Option-A** to the first list, **VO-Option-F** to the search field.
- With the second reader (above), hold its chord as well to jump the second reader instead of the keyboard.

The details are in `docs/AREAS.md`.

## Anywhere, actions, what changed, describe

- **VO-Command-A** opens Anywhere: type to narrow a list of apps, the front app's menu commands, what can be done to the
  item you are on, the app's parts and Waypoint's own commands. Return runs one, Escape closes it.
- **VO-Command-Space** lists everything that can be done to the item you are on, including its right-click menu.
- **Control-Command-W** says what is new in this part of the window since you left it; twice, in every part of the app.
- **Control-Command-0** describes the app in front and its parts; twice, as a list where Return goes to a part.
- In a list, a letter jumps to the next item that starts with it, whatever the sort order; letters typed together make a
  prefix.

## Sounds

Only skim plays a sound when it starts and ends, and a tick between items. The other tools do not mark themselves with a sound.

## Changing the keys

Every key above is a command in the key list, category Waypoint. Choose a command and press a new key, or remove its key.
The Right Command launcher is described in [the launcher](launcher.html).
