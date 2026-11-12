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
   **Page** keys jump; **Return** presses what is under the cursor.
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

## Changing the keys

Every key above is a command in the key list, category Waypoint. Choose a command and press a new key, or remove its key.
The Right Command launcher is described in [the launcher](launcher.html).
