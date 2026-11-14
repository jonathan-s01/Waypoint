# Waypoint and VoiceOver

Waypoint is a second screen reader for the Mac, a choice beside VoiceOver. One reader speaks at a time, as on every
other computer: while Waypoint is on, it reads everything and VoiceOver is off; turn Waypoint off and VoiceOver is
back. You choose which you use, and how often you switch.

## What to expect

- **Command Control Period** turns Waypoint off and on, from anywhere. Waypoint turns VoiceOver off as it starts and
  back on as it quits, so you are never without speech.
- Waypoint reads password fields and macOS's own prompts (passwords, Touch ID, "Allow" questions) itself. What you
  type into a password field is never spoken or logged: you hear a click or "star" for each
  character, never the character itself. [Privacy and security](privacy-and-security.html) says more.
- If Waypoint stops or gets stuck for more than a few seconds, VoiceOver comes on, and Waypoint starts again.
- Nothing of VoiceOver's is changed: its settings, voices and Activities stay as they are.

## Keeping some apps with VoiceOver

If VoiceOver reads an app better for you, it can keep that app while Waypoint reads the rest. In the app, press
**Command Control Shift T**: VoiceOver takes it over, and Waypoint remembers your choice next time. The same key gives
it back to Waypoint. The first press turns on **Readers per app**, in Settings, Screen reader behaviour, where you can
turn it off again.

The list of VoiceOver's apps is under Tools in the Waypoint menu, where you can also remove one. With Readers per app
on you can also choose a mode: Waypoint everywhere except your VoiceOver apps (the usual one), Waypoint only in its
own apps, or VoiceOver everywhere.

## The swap

Settings, Screen reader behaviour, **Waypoint and VoiceOver swap** is on unless you turn it off. On, one reader comes
on as the other goes off. Off, each has its own switch and neither turns the other on or off, which is for VoiceOver
reading inside a virtual machine such as Parallels. Either way, while VoiceOver is on, Waypoint is quiet.

## CoExist (experimental)

CoExist is an older way of working, kept as an experiment and off unless you turn it on (Settings, Screen reader
behaviour, Experimental). With it, VoiceOver keeps running beside Waypoint and is silenced at the sound level wherever
Waypoint reads; VoiceOver is heard in the apps you give it, in password fields and in macOS's own prompts. Waypoint's
own braille is off while it's on, as VoiceOver keeps the display. Changing it restarts Waypoint.

It can leave a Mac silent if macOS asks for audio permission while VoiceOver is muted, and a macOS or VoiceOver update
could change how it behaves. Please report anything odd.
