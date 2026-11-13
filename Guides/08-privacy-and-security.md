# Privacy and security

A screen reader has to see everything on your Mac and hear every key, so it asks for macOS's most powerful
permissions. This page says what each is for, what never leaves your Mac, and how you can check for yourself.

## The permissions, and why

- **Accessibility:** to read apps, windows and controls, and to move and press them for you. Every screen reader
  needs it.
- **Input Monitoring:** to hear Waypoint's keys (VO keys, the Waypoint layer, quick navigation). Waypoint looks at a
  key to see whether it is one of its commands; anything else goes straight on to the app.
- **Screen Recording:** only for screen recognition and describing a picture, when you ask. Both run on your Mac.
- **Automation (asked once, for one app at a time):** for example Keynote, to read a slide while a show plays.
- **Audio (CoExist, experimental and off unless you turn it on):** to keep VoiceOver's sound quiet while Waypoint reads. A small separate program,
  voiceover-quiet, mutes VoiceOver's sound and throws it away: nothing is recorded, saved or sent, and no other
  app's sound is touched.

Waypoint does not ask for Full Disk Access.

## What leaves your Mac

Waypoint connects to these places by itself:

- **Its update site**, `doll-eye.github.io/turnover-updates`, to check for a new build. Nothing about you or what you
  do is sent: it only fetches that file.
- **Apple's public catalog search**, `itunes.apple.com`, when you search in the App Store, Music or Podcasts. The
  words you searched for and your Mac's region go to Apple, as the app sends them to Apple anyway; Waypoint reads the
  answers as a plain list.
- **Hugging Face**, `huggingface.co`, once, the first time you choose a natural voice: Waypoint's voice helper
  downloads the voice, about 170 MB, and keeps it on your Mac. Nothing you read or type is sent; after that the
  natural voices need no connection.

Everything else happens on your Mac:

- Speech, including the natural voices, is made on your Mac.
- Screen recognition and picture descriptions use Apple's on-device recognition and model.
- Game speech listens only on this Mac (it accepts nothing from the network), and never speaks over Apple's apps or a
  browser. Reading Steam's Big Picture is off until you turn it on, because it makes Steam open a debugging port on
  this Mac while it runs; turning it off, or uninstalling Waypoint, removes that again.

Things you choose to send, and see before they go:

- **Send feedback** saves a report on your Desktop and opens Waypoint's problem form on GitHub in your browser. You
  write the report yourself, and attach the file only if you choose to; Waypoint never sends anything on its own.
  Reports on GitHub are public.
- **Ask for this app to be tuned** opens the request form on GitHub, filled in with how the app is built (kinds of
  item and counts, never what is in it), for you to post.

### Check it yourself

You don't have to take our word for it. Install a firewall that shows every connection, such as LuLu (free, from
objective-see.org) or Little Snitch, and use Waypoint as usual. You will see Waypoint contact TurnOver's update site, and
nothing else.

## What Waypoint keeps

Waypoint keeps a log on your Mac, in your Library folder: Application Support, TurnOver, logs. Logs older than 30
days are deleted.

- The log records what Waypoint did: the app, the kind of item, the command a key ran.
- It never records what you type. A typed key is written as "a typed key", never the key itself.
- It doesn't record the words you were reading. Where a name, a page or a message would appear, the log keeps only
  how many characters it had.

The log is plain text: you are welcome to open it and read it.

A feedback report holds these logs. "Send a report with what Waypoint said" also includes what Waypoint said aloud in
the last 15 minutes, which can be the text of an email or page you were reading; "Send a report without what
Waypoint said" leaves it out. Either way the report is a file on your Desktop: you decide whether to attach it, and
since GitHub reports are public, choose the one without what Waypoint said if anything private was on screen.

## Who can talk to Waypoint

Waypoint's own helpers (its Settings window, the Command Control Period helper, the plugin tool, Windy) reach it
through a private channel in Waypoint's own folder. Before anything is read, macOS checks that the program on the other
end is signed by TurnOver's developer; any other program is turned away and the refusal is logged. A copy you build
yourself without a developer certificate accepts only the programs inside its own app. Like any app's, Waypoint's
settings file can be changed by programs running as you; a script you give a key to asks you before it first runs.

## Apps that speak through Waypoint

An app can ask Waypoint to speak for it (a game, for example), through a port on this Mac only. Waypoint works out
for itself which program is asking (from the Mac's own records, not from what the app says), and the first time asks
you, by name, whether you trust it. An app you allow is heard only while it is the app in front, and it can do nothing
but speak: no settings, no keys. Settings, Apps that speak through Waypoint, lists them and changes your answer.

## Passwords and security prompts

Waypoint reads password fields and macOS's own prompts itself, and keeps what you type private:

- **Password fields, in any app or web page:** Waypoint says the field, and as you type you hear a click or "star" for each
  character, never the character. While a password field has the keyboard,
  macOS keeps your keys from every app but the one you are typing in, Waypoint included.
- **Typing into a password field is never spoken or logged** by Waypoint, even where an app hides that the keyboard
  is in one.
- **macOS's own prompts** (an administrator password, the keychain, Touch ID, "Allow" questions): Waypoint reads the
  prompt when it appears and puts you in it. macOS doesn't let another program press buttons in some of these, so if
  Waypoint's press is refused, it asks you to press Space yourself.

If you'd rather VoiceOver had these, CoExist (experimental, in Settings, Screen reader behaviour) gives password fields
and macOS's prompts to VoiceOver. See [Waypoint and VoiceOver](coexist.html).

## When we get something wrong

We'll say so here and in What's new.

- **18 October 2026:** in Kindle's Amazon sign-in, Waypoint read the password aloud as it was typed, because the page
  told Waypoint the keyboard was somewhere other than the password field. It was found the same day and fixed for
  every app: typing into a password field is never spoken or logged, wherever the app says the keyboard is. It
  needed an app that hides where the keyboard is, as Kindle's sign-in does; Kindle support was new that day, so we
  know of no released build where it happened.

## Questions

Ask on TurnOver's GitHub page (github.com/TurnOver-For-Mac/turnover), from the Waypoint menu, Send feedback. Something that
could expose what a person reads or types is best reported privately, through the repository's Security tab.
