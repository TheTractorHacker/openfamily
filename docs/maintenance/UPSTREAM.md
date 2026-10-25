# Relationship to the original project

OpenFamily here is an independently maintained continuation of
[wheresfrank/openfamily](https://github.com/wheresfrank/openfamily)
(AGPL-3.0). It started from that project's history, which is preserved in this
repository, and has since diverged substantially.

## Nothing depends on upstream

- No git remote, workflow, updater, container image, release asset or APK
  download in this repository points at the original repository.
- The in-app and server update paths use this repository's own signed releases.
  The old Docker-socket updater was removed.
- There is no automatic synchronization. Do not enable "Sync fork".

## Reviewing upstream changes by hand (optional)

```bash
git remote add upstream https://github.com/wheresfrank/openfamily.git
git fetch upstream
git log --oneline main..upstream/main     # what they changed
git diff main...upstream/main -- path/    # inspect before porting anything
git cherry-pick <sha>                     # port a single fix if you want it
git remote remove upstream                # when done
```

Port changes deliberately and test them. Keep the AGPL notices and the
`NOTICE` attribution intact when copying code.
