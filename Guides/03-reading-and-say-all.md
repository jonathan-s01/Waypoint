# Reading and say all

## Web pages and messages

Web pages and email messages are read as a document. Up and Down go line by line; Option with the arrows, word by
word. Single letters jump: in the Mac style, VoiceOver's Quick Nav letters (H heading, L link, F text field, T table,
1 to 6 headings by level); in the Windows style, NVDA's. **TurnOver Space** switches between reading the page and
typing into it. Enter activates a link or button.

**Which letters** (Waypoint): Settings, Web pages, "Single-letter keys on a page" chooses VoiceOver's letters, NVDA's
(K link, L list, D landmark, I list item, B button, F form field…) or whichever the keyboard style uses; any keyboard
style can use either. To give one kind your own letter, add it to `virtualBuffers.quickNavKeys` in the settings file,
by kind name, for example `"quickNavKeys": {"Landmark": "y"}`; that kind's usual letter then stops working. Shift
goes back. In a field you are typing into, letters are typed, not commands.

## Say all

Say all reads from where you are to the end: **VO A** in the Mac style, **Caps Lock A** in the Windows
style (Caps Lock Down Arrow with the desktop keyboard layout). It moves the caret as it goes.

- Any key stops it, and the caret is left on the word you had reached, not the start of the paragraph.
- Up and Down during say all skim: they move a line and carry on reading from there.

## The say all voice

Say all can read in a natural voice made on your Mac, while everything else (moving, typing, menus) stays in your
usual voice, which answers at once. The TurnOver menu, Settings, Speech, **Say all voice**: "Same as speech", or a
natural voice. Natural voice speed is there too.

The natural voice reads ahead: while one paragraph plays, the next ones are being made, so it never waits.
Natural voices speak English for now; other languages keep your Mac's voices.

## Documents

In Word, Pages and TextEdit, the arrows read as they move. **VO Command H** goes to the next heading (Shift for the
previous). In Pages, a table's line says its size; **VO Shift Down** reads it cell by cell (the arrows move, each
cell said with its row or column heading), and **VO Shift Up** or Escape comes back. Comments and highlights are
said after the line that holds them. TurnOver says the page as you move onto it.

## PDFs in Preview (experimental)

A PDF is read like a web page: line by line across pages, with "page 2 of 5" as you reach each page, and headings
by H. Highlights, notes and text boxes, which Preview hides from VoiceOver, are read where they sit.
