# Release notes for the phone apps

One file per app release, written for the people who install it, not for developers:
`docs/release/notes/<version>.md` (for example `0.26.29.md`). The technical details stay in
[the changelog](../../CHANGELOG.md).

`scripts/release-notes.sh <version>` turns the file into the body of the GitHub release (what Obtainium, the release
page and the update prompt show). The release workflow runs it. If a version has no file, the script falls back to
that version's changelog section, so a release never goes out with empty notes.

How to write one:

* Start with who needs to do what: "Update the server first" or "App update only".
* Sections, each only if it has something: **New**, **Fixed**, **Before you update**, **Not tried on a real device yet**.
* One plain sentence per bullet, what changes for the person. No codes, no key or lane words, no ticket numbers.
* Say what was NOT checked on a real phone or watch. Do not promise what was only tested on a computer.
* Optional `<version>.play.txt`: the short "What's new" for the Play Console (at most 500 characters).
