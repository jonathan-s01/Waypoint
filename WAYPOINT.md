# Waypoint: read this first (instructions for an AI agent)

Waypoint is a personal fork of TurnOver, the open-source macOS screen reader. The upstream rules in AGENTS.md,
CONTRIBUTING.md and AI-CONTRIBUTOR.md still apply. This file adds what is specific to the fork. Where they differ,
this file wins for Waypoint-only work.

## Remotes and accounts

- `origin` = https://github.com/jonathan-s01/Waypoint (the fork). `upstream` = https://github.com/TurnOver-For-Mac/turnover.
- This repo is **personal**. Use the personal account `jonathan-s01`, not the work account the app may inject.
- gh, for every command:

  ```bash
  env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR=$HOME/.config/gh-personal gh ...
  ```

- git push, pull or fetch from origin:

  ```bash
  git -c credential.https://github.com.helper= -c "credential.https://github.com.helper=!env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR=$HOME/.config/gh-personal gh auth git-credential" push origin <branch>
  ```

- Check before any push or gh write: `git remote -v`, and `gh auth status` through the override above. Never change
  global git or gh config, and never run `gh auth setup-git`.
- Commits: sign off (`-s`), author `-c user.name=jonathan-s01 -c user.email=219917501+jonathan-s01@users.noreply.github.com`,
  and end the message with this trailer:

  ```
  Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>
  ```

- Never mention the user's disability or health in any GitHub text: issues, pull requests, comments, commit messages.

## Where work goes

- **Waypoint-only work** (the rename, the README, a new interaction model, anything upstream wouldn't want) goes on
  Waypoint `main`, or on topic branches off it.
- **Anything meant for upstream** is built on a branch from `upstream/main` (run `git fetch upstream` first), never
  from Waypoint main. Test it there, push the branch to `origin`, open the pull request from the fork to upstream, and
  after that merge the branch into Waypoint main. This keeps each upstream pull request free of Waypoint's own changes.
- Keep new Waypoint code in new files, and edits to upstream's files small. Do not mass-rename TurnOver internals
  (there are about 4000 mentions); the fork has to stay mergeable.
- Keep the bundle identifier `com.turnover.reader.developer` and the folder `~/Library/Application Support/TurnOver`.
  Changing either makes macOS drop the permissions, the login item and the user's settings. Binary names and the
  Sources folder names stay too. `build.sh` names the developer build Waypoint; that is the only rename.
- The module fence (`.github/workflows/module-fence.yml`) stops a pull request from outside the project that changes
  TurnOver's core until a maintainer adds the label "core approved". Expect that for core changes, and say so in the
  pull request.

## Keeping up with upstream

Every week or two:

```bash
git fetch upstream
git merge upstream/main
./build.sh --no-install
```

- Merge, never rebase: Waypoint main is published. Never force-push main.
- On a conflict in a file upstream owns, prefer upstream's version unless the Waypoint change is the point of that
  file. If a conflict is large or you can't tell what upstream meant, stop and ask.
- The tests must all pass afterwards. Then `git push origin main` (fast-forward only).
- Our CHANGELOG and README entries sit beside upstream's; never replace theirs.

## Contributing to upstream

Follow AI-CONTRIBUTOR.md and CONTRIBUTING.md. In short:

- An issue and a pull request together; the pull request says `Closes #N`. Look for duplicates first
  (`gh issue list -R TurnOver-For-Mac/turnover --search ...`, and `gh pr list`). Larger or shared-behaviour changes
  (focus, speech, keys, VoiceOver hand-over) need the issue first.
- Model new issues and pull requests on jonathan-s01's #238 and #239: an **AI disclosure** paragraph (written by
  the named AI at the user's request; the user tested by ear but is not a Swift developer), then **What it does**,
  **How it was checked** and **Not checked**. Plain, short, true.
- One topic per pull request. Every commit signed off (DCO). A CHANGELOG entry in upstream's style under its current
  top section. Tests where you can (`Sources/TurnOverTests`, the custom harness, not XCTest).
- "Checked by ear" means the user listened and said so. Claim only what the user did in real use, and what the tests
  and logs show. Anything else (other keyboard styles, other voices, other apps, braille) goes under Not checked.
- No private content (mail, chats, documents) in fixtures, logs or text.
- **Ask the user before anything that posts to GitHub upstream** (issue, pull request, comment): show the text first.

## Building and installing

- `./build.sh --no-install`: about 90 seconds; builds, runs about 581 tests and the helper self-tests, and leaves
  `~/Library/Developer/TurnOver/build/Waypoint.app`. Do not run two builds at once: they share that folder.
- The build rewrites `Resources/Localizable.xcstrings`. Revert it afterwards with
  `git checkout Resources/Localizable.xcstrings`, unless you added translatable strings and mean to commit them.
- `./build.sh` installs to /Applications/Waypoint.app and **restarts the reader**, which interrupts the user's
  speech. Tell the user first and wait for a yes. Afterwards check `pgrep -x turnover`, and read the newest log in
  `~/Library/Application Support/TurnOver/logs/`. If the reader isn't running, start VoiceOver (`open -a VoiceOver`).
- Quit the app before editing `settings.json` by hand; it rewrites the file as it quits.
- Find processes with `pgrep` and stop them by PID with `kill <PID>`. No `pkill` or `killall`.
- Speech changes are checked by ear. A passing build does not say how something sounds.
- Do not touch `~/Desktop/turnover` or `~/Desktop/Full system`; the user keeps those for other work.

## Ideas parked

- **Cancel fade.** Cancelling speech with a hard `player.stop()` (`SpeechPlayer.cancelOnQueue`) can click.
  AVAudioEngine's mixer volume ramps over about 27 ms and ignores a 2 ms ramp, so a short fade can't be made that
  way. A custom `AUAudioUnit` gain node with a ramp of about 1.5 ms would do it. Risks: the audio-core recovery paths
  (it must survive device changes and restarts), and about 3 ms added to every cancel. Not started.
