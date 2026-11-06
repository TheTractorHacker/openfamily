# License compliance audit (issue #26)

Date: 2026-11. Scope: repository at v0.13.3 plus this branch. Not legal advice.

## Conclusion

1. **Project license:** `LICENSE` is the GNU AGPL-3.0 text. `NOTICE` keeps the attribution to the original OpenFamily authors (https://github.com/wheresfrank/openfamily), which this project continues. `scripts/license-check.sh` fails CI if either is lost.
2. **Vendored code:** `app/packages/background_locator_2` is a fork of an MIT-licensed plugin (Copyright 2020 REKAB, 2022 Yukams). The MIT notice is kept in the package directory and now recorded in `NOTICE` and `docs/THIRD_PARTY_LICENSES.md`. MIT is compatible with AGPL-3.0 as long as the notice is preserved. `app/packages/driving_native` is first-party.
3. **Go dependencies (16 modules):** MIT, BSD-3-Clause, ISC (coder/websocket) and Apache-2.0 (pquerna/otp). All are compatible with AGPL-3.0. Apache-2.0 is compatible with GPLv3/AGPLv3.
4. **Flutter dependencies (170 locked packages):** BSD-style (119), MIT (31), Apache-2.0 (11), MPL-2.0 (`dbus`, `nm`, `upower`, Linux-only transitive packages not in the Android/iOS builds), plus SDK-provided packages. Compatible. MPL-2.0 files remain under MPL-2.0 (file-level copyleft) and MPL-2.0 section 3.3 permits combination with AGPL.
5. **Admin web dependencies:** production deps are MIT/ISC/BSD/Apache/dual-MIT-Apache **except two**; dev-only tooling (lightningcss, MPL-2.0) is not distributed in the built bundle.
6. **Network source offer (AGPL section 13):** the source location is stated in `NOTICE`, `README.md` and the GitHub repository. See "Open findings" for the in-product link.

## Open findings

| # | Finding | Impact | Recommendation |
|---|---|---|---|
| L1 | `react-leaflet` 4.2.1 and `@react-leaflet/core` 2.1.0 (admin web, production bundle) are under the **Hippocratic License 2.1**, an ethical-source license with use restrictions; it is not OSI-approved and, in our reading, adds restrictions the AGPL forbids when combined in one distributed work. | Distribution of the built admin bundle (`backend/web/dist`) may not be license-compliant. | Replace react-leaflet with direct Leaflet/maplibre usage (Leaflet itself is BSD-2-Clause and is already a dependency), or obtain a written exception from the authors. Needs a maintainer decision and visual regression testing; **not done here**. Tracked as an exception in `scripts/license-exceptions.txt` so CI stays green but visible. |
| L2 | No in-product link to the corresponding source for network users (AGPL section 13). | A modified deployment would need to add it; the unmodified project is served from the public repo. | Add a "Source code" link and the running commit to the admin footer and app About screen (small web/app change; not done here to avoid conflicts with UI work). |
| L3 | Dart license detection for the inventory is heuristic (license text matching, packages without a LICENSE file are the SDK ones). | Low | Re-run an inventory with `flutter pub deps` plus manual review on major dependency changes. |
| S1 | `maplibre-gl` 5.24.0 has an open critical advisory (GHSA-jrc7-96c5-q579, DOM.sanitize bypass), fixed in 6.x. | Admin map XSS vector if untrusted HTML reaches the sanitizer. | Upgrade to 6.x with a visual pass; CI `npm-audit` is `continue-on-error` until then. |

`govulncheck ./...` on the backend (Go 1.27.3, govulncheck v1.9.0): 0 vulnerabilities affecting called code; 3 advisories in required modules whose vulnerable code is not called.

## Checks

`scripts/license-check.sh` (CI job `licenses` in `.github/workflows/security.yml`) verifies: AGPL `LICENSE`, `NOTICE` attribution, vendored MIT notice, every Go module / hosted pub package / production npm package present in `docs/THIRD_PARTY_LICENSES.md`, and every npm license on the allow-list or in `scripts/license-exceptions.txt`.
