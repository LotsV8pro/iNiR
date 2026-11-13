<p align="center">
  <img src="https://img.shields.io/badge/Niri-141218?style=for-the-badge&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/Quickshell_%2F_QML-141218?style=for-the-badge&logo=qt&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/Arch_Linux-141218?style=for-the-badge&logo=arch-linux&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/GPL--3.0-141218?style=for-the-badge&logo=open-source-initiative&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/github/v/release/LotsV8pro/iNiR?style=for-the-badge&color=141218"/>
</p>

<h1 align="center">iNiR · Lotus</h1>

The iNiR shell for Niri, with the things I put on top. This is not a separate
shell: it is iNiR 3.1.1 with local patches, so the desktop behaves the way I
use it and can still be updated from the original repository.

The interface and the documentation of the shell are the ones from
[snowarch/iNiR](https://github.com/snowarch/iNiR); everything below is what
this copy adds.

## What it changes

**Each screen keeps its own colour.** The widget palette used to be solved once
per session, seeded with the wallpaper applied last, and that application
belongs to the screen in use. A widget on the other monitor wore the hues of
the picture next to it, and its colour changed whenever that other desk got a
new wallpaper. Now each widget takes the hue and the chroma of the picture
under its own screen, keeping the lightness the family solved; a picture with
no colour leaves the marks neutral instead of inventing a tint. The wallpaper
palette (the lighter and darker steps of a single tone) reads the picture under
the widget too, and the OrganicEdge panel and the Japanese typography face read
their own screen.

**A widget belongs to the screen where you put it.** Turning one on from the
shelf or from the quick controls adds it to that desk, not to every monitor.
Settings keeps its switch for all screens. Stacks do the same with their pages:
each screen shows its own page, turns on its own timer, and moving a page up on
one leaves the other as it was.

**The widgets sing the player's own words.** The lyric surfaces ask for a
player that can carry lyrics, so a YouTube or Twitch tab no longer sends them
looking for words that do not exist. The line fills word by word when the
source stamped the words and whole when it only knows when the line starts; a
stretch without voice is three dots that light one by one. When Lotus Tune is
the one playing, it publishes the lyrics it found with the timestamp of every
word, and the widgets use those timings instead of downloading a second
version of the song.

**The video wallpaper has its own still underneath.** While the two video slots
blend, their opacities do not add up to one, and the gap used to show whatever
sat under the surface. The clip's first frame now sits under the player, and
`awww` paints that still on the output instead of skipping it.

**Google Calendar.** The calendar reads Google over OAuth (loopback redirect,
or the device code from a terminal): its events join the iCal feeds, contacts
offer names and birthdays when you write one, and a new event can be pushed
back to Google. Contacts live in their own cache so the composer does not walk
the whole calendar on each keystroke. It is off until you put your own OAuth
client in `calendar.googleOAuth` (`clientId`, `clientSecret`, `pushEnabled`,
`importDays`); then `inir ipc calendar authorize` opens the browser once.

**The recorder picks its device.** Under the audio mode there is a row for the
microphone and another for the system sound, each opening the mixer's list over
the panel. `Default` follows whatever the mixer says when the recording starts;
picking a name pins it.

**The config is written when you stop, not while you drag.** The shell kept the
live value in memory and rewrote the whole 157 KB file every 50 ms; the write
now waits 400 ms after the last change.

## What it does not change

The three families (Material, iRiS, Waffle), the panels, the hub, the settings
and the rest of the shell are upstream's. The documentation in `docs/` is
upstream's too, in English. Fixes that only touch the hub plugin are not here on
purpose: an update rewrites that plugin, so anything that has to survive lives
in this repository.

## Install

This copy is built for the machine it runs on (Arch, Niri, Quickshell). The way
I install it:

```bash
git clone https://github.com/LotsV8pro/iNiR.git
cd iNiR
./setup install -y
```

Upstream's installer, dependencies and options are described in
[docs/INSTALL.md](docs/INSTALL.md). The shell then lives as a user service:

```bash
systemctl --user status inir.service
```

Never stop it with `pkill`: `systemctl --user restart inir.service` is the way
to restart the shell, and saving a QML file reloads it.

## Update

```bash
cd ~/inir
git pull --rebase
./setup update -y
```

With local commits of your own, `inir update` refuses to run when the checkout
is both ahead and behind. On this machine that is solved with
`inir-update-local`, which fetches upstream, bundles a backup, rebases the local
commits on top and only then calls `./setup update -y`; a conflict aborts and
leaves the tree as it was.

## Known limits

- A few marks inside the hub plugin (the "today" of the calendar and the clock,
  the stack chips, the borders of the quick controls) still read the session
  accent, so they follow the screen in use. They are not visible with the
  widgets this desktop uses; making them exact needs a patch to the plugin,
  which an update would overwrite.
- On the screen with the video wallpaper, the seed comes from the cached first
  frame, not from the moving clip. It is the same limit the region colours had.
- The Google Calendar connection has no button in Settings yet: it is configured
  in the JSON and authorised from a terminal.
- The recorder lists the devices `pactl` reports; a device that appears while
  the panel is open shows up within eight seconds.

## Related

| Repo | What it is |
|---|---|
| [Lotus-Arch](https://github.com/LotsV8pro/Lotus-Arch) | The Arch desktop this shell runs on |
| [lotus-tune](https://github.com/LotsV8pro/lotus-tune) | The player whose lyrics the widgets use |
| [lotus-mic-chain](https://github.com/LotsV8pro/lotus-mic-chain) | Microphone chain for EasyEffects |

## Credits

| Project | Used for |
|---|---|
| [snowarch/iNiR](https://github.com/snowarch/iNiR) | The shell this copy is built on (GPL-3.0) |
| [Quickshell](https://quickshell.org) | The QML runtime |
| [Niri](https://github.com/YaLTeR/niri) | The compositor |
| [iNiR Hub](https://inir.space/hub) | Families, widgets and themes |

Licensed under GPL-3.0, like the shell it comes from.
