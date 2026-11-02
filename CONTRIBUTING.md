# Contributing

Thanks for looking. A few things will save us both some time.

## Bugs

Open an issue and tell me what happened, your macOS version, and whether you were on the sample mess or a real desktop. If a file ended up somewhere it shouldn't, say so in the title and I'll look at that first.

You can find a log of everything RoboDust did to your files in `~/Library/Application Support/RoboDust/history.log`. It has your file names in it, so read it before you paste it anywhere public.

## Ideas and pull requests

For anything bigger than a small fix, open an issue before you write the code. I'd hate for you to spend a weekend on something I'd have told you I wasn't going to take.

I read every pull request myself, and I'll only merge what's genuinely good for RoboDust. The question I ask is whether it makes the robot more fun or your files safer. A no isn't a comment on your work, and it's MIT, so you can always keep it in your own copy.

Probably yes:

- anything that makes it feel more like a real robot
- safety fixes, especially around unusual files and setups
- support for more setups, like multiple displays and Spaces
- bug fixes, including small ones

Probably no:

- accounts, ads, analytics, or anything that sends your data anywhere
- settings for things that should just work
- big rewrites without talking first

## Please don't test on your real desktop

This app deletes files, and a bug on your real desktop is a very bad afternoon. Use the sample mess, or point it at a throwaway folder. All of these run from the built app:

```
# Build
scripts/build.sh
B=build/RoboDust.app/Contents/MacOS/RoboDust

# Checks the file actions on throwaway files in the folder you give it.
# One tiny test file goes to the real Trash and comes straight back.
mkdir -p /tmp/robodust-test && $B --fileops-test /tmp/robodust-test

# Same idea for iCloud-only files. Needs iCloud Drive, and briefly syncs a few small test files.
$B --icloud-test

# A real run with a throwaway folder standing in for your desktop.
# 0 is Tidy up, 1 is Trash, 2 is Delete. It really does delete what's in that folder.
$B --auto --no-hide --test-root /tmp/robodust-test --test-mode 2

# Draws a run offscreen and saves frames as PNGs, using the sample mess. Good for checking motion.
$B --dump 4,8,12 --pixel-scale 2 --follow 900 --out /tmp/robodust-test
```

If your change touches `FileOps.swift`, run `--fileops-test`, add a check for the new behaviour, and tell me what you ran in the pull request.

## Keeping it small

Match the code around you, and keep changes to one thing at a time. Releases are built and signed on my side with `scripts/release.sh`, so you don't need an Apple developer account to contribute.

By opening a pull request, you agree that your work goes in under the [MIT license](LICENSE).
