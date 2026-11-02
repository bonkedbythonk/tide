# Privacy

What Tide sends, to whom, and what it keeps. There is no analytics, no
telemetry, no crash reporting and no account of its own. The hosts below are
literals in `Sources/MusicSample/`, or are the ones yt-dlp contacts.

## What leaves your machine, and when

| To | When | What they see |
|---|---|---|
| Google sign-in (`accounts.google.com`) | Signing in, in the app's sign-in window | What any Google sign-in sees |
| YouTube Music (`music.youtube.com`) | Browsing, searching, opening pages, and once per new song to read its loudness | Your IP, your account (through your sign-in cookies) and what you browse and play |
| YouTube and its media servers (`www.youtube.com`, `*.googlevideo.com`), through yt-dlp | Playing a song, and fetching the next few songs ahead of time | Your IP, your account and the songs played |
| Cover art hosts (`*.googleusercontent.com`, `i.ytimg.com`) | Showing covers | Your IP and the images loaded |
| LRCLIB (`lrclib.net`) | Showing lyrics | Your IP and the song's title, artist, album and length |

## What stays on your machine

- The sign-in cookies, in the app's own web view store, and a copy for yt-dlp
  at `~/Library/Application Support/MusicApp/cookies.txt` (owner-only, 0600).
- `~/Library/Application Support/MusicApp/cache/`: your library, pages, lyrics
  and loudness values, so the app opens instantly. Safe to delete.
- `~/Library/Caches/MusicApp/images/`: downloaded cover art.
- Settings and your last queue and position, in the app's preferences.
- With a Pinstill wallpaper, Tide reads Pinstill's settings to find your
  boards and reads the pictures in those folders. It changes nothing there.

Sign Out (in Settings) removes the sign-in cookies and the cached library.
Downloaded cover art stays in `~/Library/Caches/` until macOS or you clear it.

## What Tide does not do

- No analytics, telemetry or crash reporting to anyone, including the developer.
- No account, no server of the developer's, nothing hosted.

## Questions

Open an issue on the repository. Security matters go through GitHub's
[private advisory form](https://github.com/bonkedbythonk/tide/security/advisories/new).
