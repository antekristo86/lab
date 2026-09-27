# take

A free Mac recorder that listens. Vertical first. The largest 9:16,
4:5, 1:1 or 16:9 crop of what the camera sends, written straight to
HEVC.

The teleprompter follows your voice. Spoken words dim, it waits while
you improvise and finds you again, even a few sentences further on.
Four spoken commands run the take: take start, take again, take end,
take reset. A spoken take end is trimmed off the take, unless you keep
it. Speech recognition runs on the Mac. No account, no analytics, no
network requests.

The app is four Swift files. No Xcode project, no dependencies.

- `demo.html`, the page.
- `source/`, the app.

Get it: https://take.ante.design

Or build it, macOS 14 or later, with Xcode or the Command Line Tools:

    npx degit antekristo86/lab/take take
    cd take
    ./source/build.sh
    open source/build/take.app

`./source/release.sh` builds the universal disk image.

Made with Claude Code.
