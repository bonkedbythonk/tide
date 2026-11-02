# Contributing to Tide

Thanks for wanting to help. Tide is maintained by one person, so the most
useful contributions are clear bug reports and small, focused pull requests.

## Reporting a bug

Open an issue with the **Bug report** template. Say what you did, what you
expected and what happened, plus your macOS version and the commit you built
from (`git rev-parse --short HEAD`). If playback fails, run `yt-dlp --version`
and include that too: most playback problems are an outdated yt-dlp, fixed by
`brew upgrade yt-dlp`.

Security problems do not go in public issues; use GitHub's
[private advisory form](https://github.com/bonkedbythonk/tide/security/advisories/new).

## Suggesting a feature

Open an issue with the **Feature request** template and describe the problem
you want solved, not only the solution.

## Development setup

Tide is a Swift package: SwiftUI, with libmpv in-process through
[MPVKit](https://github.com/bonkedbythonk/MPVKit). Songs are resolved by a
long-running yt-dlp worker on Homebrew's Python.

```bash
brew install yt-dlp deno
swift build          # debug build, to check it compiles
./run.sh             # release build, wrapped in Tide.app and opened
```

You need an Apple silicon Mac on macOS 15 or later and the Xcode command line
tools (Swift 6).

For screenshots, `Scripts/demo.sh` opens a second Tide window filled with
made-up songs and abstract covers (needs ImageMagick). Pass `playlist`,
`nowplaying` or `settings` to open on that screen. It leaves your own library,
queue and caches alone.

## Pull requests

- One change per pull request, with how you tested it.
- Match the code around you; write the least code the change needs.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
  (`feat:`, `fix:`, `style:` ...), in English, with no emojis.
- By contributing you agree your work is licensed under [GPLv3](LICENSE).
