# Compatibility policy (short version)

The server supports the **last 5 released minor versions** of the app. Rules for
contributors:

1. Add fields; never remove or rename a field an in-window app reads.
2. New behaviour that needs a newer app goes through `compat.Features` in
   `backend/internal/compat`, so older apps get a clear "update the app"
   message instead of an empty screen.
3. When the owner tags a release, add its `x.y.0` to `compat.Releases` and add a
   section to [CHANGELOG.md](../CHANGELOG.md) in the same commit. A test fails
   until both are done.
4. Admins see the result on **Settings, App versions**
   ([guide](../admin/app-versions.md)).

The full contract, headers, 426 enforcement and the contract test:
[API compatibility](../api-compat.md).
