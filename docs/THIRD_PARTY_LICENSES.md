# Third-party licenses

OpenFamily is licensed under the GNU Affero General Public License v3.0 (see
[LICENSE](../LICENSE)). This file inventories the third-party components that
are built into, or shipped with, the project and the license each one is
distributed under. See [NOTICE](../NOTICE) for upstream attribution and the
network-source offer, and [LICENSE_COMPLIANCE.md](LICENSE_COMPLIANCE.md) for
the audit conclusion.

Source of truth: `backend/go.mod`, `app/pubspec.lock`, `web/package-lock.json`.
`scripts/license-check.sh` fails CI if a dependency in those files is missing
from this inventory or uses a disallowed license. Licenses below were read from
each package's own license file or registry metadata when the inventory was
written; where a heuristic was used for Dart packages it matched the license
text (MIT / BSD-style / Apache-2.0 / MPL-2.0).

## Vendored in this repository

| Component | Path | License | Notes |
|---|---|---|---|
| background_locator_2 | `app/packages/background_locator_2` | MIT (Copyright 2020 REKAB, Copyright 2022 Yukams) | Vendored and modified fork; upstream LICENSE kept in the package directory. |
| driving_native | `app/packages/driving_native` | AGPL-3.0 (this project) | First-party plugin. |
| Original OpenFamily | whole project | AGPL-3.0 | Continues https://github.com/wheresfrank/openfamily; see NOTICE. |

## Backend (Go modules, `backend/go.mod`)

| Module | Version | License |
|---|---|---|
| github.com/boombuler/barcode | v1.0.1-0.20190219062509-6c824513bacc | MIT |
| github.com/coder/websocket | v1.8.15 | ISC |
| github.com/go-chi/chi/v5 | v5.3.1 | MIT |
| github.com/golang-jwt/jwt/v5 | v5.3.1 | MIT |
| github.com/golang-migrate/migrate/v4 | v4.19.1 | MIT |
| github.com/jackc/pgpassfile | v1.0.0 | MIT |
| github.com/jackc/pgservicefile | v0.0.0-20240606120523-5a60cdf6a761 | MIT |
| github.com/jackc/pgx/v5 | v5.10.0 | MIT |
| github.com/jackc/puddle/v2 | v2.2.2 | MIT |
| github.com/lib/pq | v1.10.9 | MIT |
| github.com/pquerna/otp | v1.5.0 | Apache-2.0 |
| filippo.io/age | v1.3.2 | BSD-3-Clause |
| filippo.io/hpke | v0.4.0 | BSD-3-Clause |
| github.com/cespare/xxhash/v2 | v2.3.0 | MIT |
| github.com/dustin/go-humanize | v1.0.1 | MIT |
| github.com/klauspost/compress | v1.19.2 | BSD-3-Clause, Apache-2.0, MIT (per file) |
| github.com/klauspost/cpuid/v2 | v2.4.0 | MIT |
| github.com/klauspost/crc32 | v1.3.0 | BSD-3-Clause |
| github.com/minio/crc64nvme | v1.1.1 | Apache-2.0 |
| github.com/minio/md5-simd | v1.1.2 | Apache-2.0 |
| github.com/minio/minio-go/v7 | v7.4.1 | Apache-2.0 |
| github.com/rs/xid | v1.6.0 | MIT |
| github.com/zeebo/xxh3 | v1.1.0 | BSD-2-Clause |
| github.com/go-webauthn/webauthn | v0.18.2 | BSD-3-Clause |
| github.com/fxamacker/cbor/v2 | v2.9.4 | MIT |
| github.com/go-viper/mapstructure/v2 | v2.5.0 | MIT |
| github.com/go-webauthn/x | v0.3.1 | BSD-3-Clause |
| github.com/google/go-tpm | v0.9.8 | Apache-2.0 |
| github.com/google/uuid | v1.6.0 | BSD-3-Clause |
| github.com/philhofer/fwd | v1.2.0 | MIT |
| github.com/tinylib/msgp | v1.6.4 | MIT |
| github.com/x448/float16 | v0.8.4 | MIT |
| go.yaml.in/yaml/v3 | v3.0.5 | MIT, Apache-2.0 |
| golang.org/x/net | v0.60.0 | BSD-3-Clause |
| gopkg.in/ini.v1 | v1.67.3 | Apache-2.0 |
| golang.org/x/crypto | v0.55.0 | BSD-3-Clause |
| golang.org/x/sync | v0.22.0 | BSD-3-Clause |
| golang.org/x/sys | v0.47.0 | BSD-3-Clause |
| golang.org/x/text | v0.41.0 | BSD-3-Clause |

## Admin web (npm, `web/package-lock.json`, production dependencies)

Development-only tooling (vite, typescript, eslint, lightningcss, ...) is not
distributed in the built admin bundle and is covered by the `scripts/license-check.sh`
license gate rather than listed here.

| Package | Version | License |
|---|---|---|
| require-from-string | 2.0.2 | MIT |
| bidi-js | 1.1.0 | MIT |
| @noble/ciphers | 2.4.0 | MIT |
| @noble/curves | 2.4.0 | MIT |
| @noble/hashes | 2.4.0 | MIT |
| @mapbox/jsonlint-lines-primitives | 2.0.3 | MIT |
| @mapbox/point-geometry | 1.1.0 | ISC |
| @mapbox/tiny-sdf | 2.3.0 | BSD-2-Clause |
| @mapbox/unitbezier | 1.0.0 | BSD-2-Clause |
| @mapbox/vector-tile | 3.0.0 | BSD-3-Clause |
| pbf | 5.1.2 | BSD-3-Clause |
| @mapbox/whoots-js | 3.1.0 | ISC |
| @maplibre/geojson-vt | 6.3.0 | ISC |
| @maplibre/maplibre-gl-leaflet | 0.1.4 | ISC |
| @maplibre/maplibre-gl-style-spec | 26.5.1 | ISC |
| @mapbox/unitbezier | 1.0.0 | BSD-2-Clause |
| @maplibre/mlt | 1.3.0 | (MIT OR Apache-2.0) |
| @maplibre/vt-pbf | 4.3.3 | MIT |
| @react-leaflet/core | 2.1.0 | Hippocratic-2.1 |
| @types/geojson | 7946.0.16 | MIT |
| @types/leaflet | 1.9.22 | MIT |
| earcut | 3.2.4 | ISC |
| gl-matrix | 3.4.4 | MIT |
| js-tokens | 4.0.0 | MIT |
| json-stringify-pretty-compact | 4.0.0 | MIT |
| kdbush | 4.1.0 | ISC |
| leaflet | 1.9.4 | BSD-2-Clause |
| loose-envify | 1.4.0 | MIT |
| maplibre-gl | 6.16.0 | BSD-3-Clause |
| pbf | 5.1.2 | BSD-3-Clause |
| minimist | 1.2.8 | MIT |
| murmurhash-js | 1.0.0 | MIT |
| pbf | 5.1.2 | BSD-3-Clause |
| potpack | 2.1.0 | ISC |
| protocol-buffers-schema | 3.6.1 | MIT |
| quickselect | 3.0.0 | ISC |
| react | 18.3.1 | MIT |
| react-dom | 18.3.1 | MIT |
| react-leaflet | 4.2.1 | Hippocratic-2.1 |
| resolve-protobuf-schema | 2.1.0 | MIT |
| scheduler | 0.23.2 | MIT |
| tinyqueue | 3.0.0 | ISC |

**Attention:** `react-leaflet` and `@react-leaflet/core` are licensed under the
Hippocratic License 2.1, an "ethical source" license that is not OSI-approved
and adds field-of-use restrictions that are not compatible with the AGPL's
"no further restrictions" rule. See LICENSE_COMPLIANCE.md for the finding and
the recommended replacement.

## Flutter app (pub, `app/pubspec.lock`)

The Flutter SDK itself (BSD-3-Clause) and the packages it provides (`flutter`, `flutter_test`, `flutter_web_plugins`, `sky_engine`) are not listed individually.

| Package | Version | License |
|---|---|---|
| android_intent_plus | 5.3.1 | BSD-style |
| args | 2.7.0 | BSD-style |
| async | 2.13.1 | BSD-style |
| background_locator_2 | 2.0.6 | MIT (vendored, see above) |
| battery_plus | 6.2.3 | BSD-style |
| battery_plus_platform_interface | 2.0.1 | BSD-style |
| boolean_selector | 2.1.2 | BSD-style |
| characters | 1.4.1 | BSD-style |
| bip39 | 1.0.6 | BSD-3-Clause |
| convert | 3.1.2 | BSD-3-Clause |
| cryptography | 2.9.0 | Apache-2.0 |
| hex | 0.2.0 | MIT |
| pointycastle | 3.9.1 | MIT |
| clock | 1.1.2 | Apache-2.0 |
| code_assets | 1.2.1 | BSD-style |
| collection | 1.19.1 | BSD-style |
| connectivity_plus | 6.1.5 | BSD-style |
| connectivity_plus_platform_interface | 2.1.0 | BSD-style |
| cross_file | 0.3.5+4 | BSD-style |
| crypto | 3.0.7 | BSD-style |
| dart_earcut | 1.2.0 | MIT |
| dbus | 0.7.14 | MPL-2.0 |
| driving_native | 0.1.0 | AGPL-3.0 (first party) |
| executor_lib | 1.1.2 | BSD-style |
| fake_async | 1.3.3 | Apache-2.0 |
| ffi | 2.2.0 | BSD-style |
| file | 7.0.1 | BSD-style |
| file_selector_linux | 0.9.4 | BSD-style |
| file_selector_macos | 0.9.5 | BSD-style |
| file_selector_platform_interface | 2.7.0 | BSD-style |
| file_selector_windows | 0.9.3+5 | BSD-style |
| fixnum | 1.1.1 | BSD-style |
| flutter | 0.0.0 | BSD-3-Clause (Flutter SDK) |
| flutter_lints | 4.0.0 | BSD-style |
| flutter_local_notifications | 22.3.0 | BSD-style |
| flutter_local_notifications_linux | 8.0.1 | BSD-style |
| flutter_local_notifications_platform_interface | 12.2.0 | BSD-style |
| flutter_local_notifications_web | 1.0.0 | BSD-style |
| flutter_local_notifications_windows | 3.1.1 | BSD-style |
| flutter_map | 7.0.2 | BSD-style |
| flutter_native_contact_picker | 0.0.12 | BSD-style |
| flutter_plugin_android_lifecycle | 2.0.35 | BSD-style |
| flutter_secure_storage | 9.2.4 | BSD-style |
| flutter_secure_storage_linux | 1.2.3 | BSD-style |
| flutter_secure_storage_macos | 3.1.3 | BSD-style |
| flutter_secure_storage_platform_interface | 1.1.2 | BSD-style |
| flutter_secure_storage_web | 1.2.1 | BSD-style |
| flutter_secure_storage_windows | 3.1.2 | BSD-style |
| flutter_test | 0.0.0 | BSD-3-Clause (Flutter SDK) |
| flutter_web_plugins | 0.0.0 | BSD-3-Clause (Flutter SDK) |
| geolocator | 13.0.4 | MIT |
| geolocator_android | 4.6.2 | MIT |
| geolocator_apple | 2.3.14 | MIT |
| geolocator_platform_interface | 4.2.8 | MIT |
| geolocator_web | 4.1.4 | MIT |
| geolocator_windows | 0.2.5 | MIT |
| google_api_availability | 5.0.1 | MIT |
| google_api_availability_android | 1.1.1 | MIT |
| google_api_availability_platform_interface | 1.0.1 | MIT |
| hooks | 2.0.2 | BSD-style |
| http | 1.6.0 | BSD-style |
| http_parser | 4.1.2 | BSD-style |
| image_picker | 1.2.3 | BSD-style |
| image_picker_android | 0.8.13+19 | BSD-style |
| image_picker_for_web | 3.1.1 | BSD-style |
| image_picker_ios | 0.8.13+6 | BSD-style |
| image_picker_linux | 0.2.2 | BSD-style |
| image_picker_macos | 0.2.2+1 | BSD-style |
| image_picker_platform_interface | 2.11.1 | BSD-style |
| image_picker_windows | 0.2.2 | BSD-style |
| intl | 0.20.3 | BSD-style |
| jni | 1.0.3 | BSD-style |
| jni_flutter | 1.0.2 | BSD-style |
| jni_util | 1.0.0 | BSD-style |
| js | 0.6.7 | BSD-style |
| json_annotation | 4.12.0 | BSD-style |
| latlong2 | 0.9.1 | Apache-2.0 |
| leak_tracker | 11.0.2 | BSD-style |
| leak_tracker_flutter_testing | 3.0.10 | BSD-style |
| leak_tracker_testing | 3.0.2 | BSD-style |
| lints | 4.0.0 | BSD-style |
| lists | 1.0.1 | BSD-style |
| local_auth | 2.3.0 | BSD-style |
| local_auth_android | 1.0.56 | BSD-style |
| local_auth_darwin | 1.6.1 | BSD-style |
| local_auth_platform_interface | 1.1.0 | BSD-style |
| local_auth_windows | 1.0.11 | BSD-style |
| logger | 2.7.0 | MIT |
| logging | 1.3.0 | BSD-style |
| matcher | 0.12.19 | BSD-style |
| material_color_utilities | 0.13.0 | Apache-2.0 |
| meta | 1.18.0 | BSD-style |
| mgrs_dart | 2.0.0 | MIT |
| mime | 2.0.0 | BSD-style |
| nm | 0.5.0 | MPL-2.0 |
| objective_c | 9.5.0 | BSD-style |
| package_config | 3.0.0 | BSD-style |
| package_info_plus | 8.3.1 | BSD-style |
| package_info_plus_platform_interface | 3.2.1 | BSD-style |
| path | 1.9.1 | BSD-style |
| path_provider | 2.1.6 | BSD-style |
| path_provider_android | 2.3.1 | BSD-style |
| path_provider_foundation | 2.6.0 | BSD-style |
| path_provider_linux | 2.2.2 | BSD-style |
| path_provider_platform_interface | 2.1.3 | BSD-style |
| path_provider_windows | 2.3.0 | BSD-style |
| permission_handler | 11.4.0 | MIT |
| permission_handler_android | 12.1.0 | MIT |
| permission_handler_apple | 9.6.1 | MIT |
| permission_handler_html | 0.1.4+1 | MIT |
| permission_handler_platform_interface | 4.4.0 | MIT |
| permission_handler_windows | 0.2.2 | MIT |
| petitparser | 7.0.2 | MIT |
| platform | 3.1.6 | BSD-style |
| plugin_platform_interface | 2.1.8 | BSD-style |
| polylabel | 1.0.1 | BSD-style |
| proj4dart | 2.1.0 | MIT |
| protobuf | 3.1.0 | BSD-style |
| pub_semver | 2.2.0 | BSD-style |
| qr | 3.0.2 | BSD-style |
| qr_flutter | 4.1.0 | BSD-style |
| record_use | 0.6.0 | BSD-style |
| screen_retriever | 0.2.2 | MIT |
| screen_retriever_linux | 0.2.2 | MIT |
| screen_retriever_macos | 0.2.2 | MIT |
| screen_retriever_platform_interface | 0.2.2 | MIT |
| screen_retriever_windows | 0.2.2 | MIT |
| sensors_plus | 7.1.1 | BSD-style |
| sensors_plus_platform_interface | 2.0.2 | BSD-style |
| share_plus | 10.1.4 | BSD-style |
| share_plus_platform_interface | 5.0.2 | BSD-style |
| shared_preferences | 2.5.5 | BSD-style |
| shared_preferences_android | 2.4.27 | BSD-style |
| shared_preferences_foundation | 2.5.6 | BSD-style |
| shared_preferences_linux | 2.4.1 | BSD-style |
| shared_preferences_platform_interface | 2.4.2 | BSD-style |
| shared_preferences_web | 2.4.3 | BSD-style |
| shared_preferences_windows | 2.4.1 | BSD-style |
| sky_engine | 0.0.0 | BSD-3-Clause (Flutter SDK) |
| source_span | 1.10.2 | BSD-style |
| stack_trace | 1.12.1 | BSD-style |
| stream_channel | 2.1.4 | BSD-style |
| string_scanner | 1.4.1 | BSD-style |
| term_glyph | 1.2.2 | BSD-style |
| test_api | 0.7.11 | BSD-style |
| timezone | 0.11.1 | BSD-style |
| typed_data | 1.4.0 | BSD-style |
| unicode | 0.3.1 | BSD-style |
| unifiedpush | 6.2.0 | Apache-2.0 |
| unifiedpush_android | 3.4.1 | Apache-2.0 |
| unifiedpush_linux | 1.0.0 | Apache-2.0 |
| unifiedpush_platform_interface | 4.0.0 | Apache-2.0 |
| unifiedpush_storage_interface | 1.0.0 | Apache-2.0 |
| upower | 0.7.0 | MPL-2.0 |
| url_launcher_linux | 3.2.2 | BSD-style |
| url_launcher_platform_interface | 2.3.2 | BSD-style |
| url_launcher_web | 2.4.3 | BSD-style |
| url_launcher_windows | 3.1.5 | BSD-style |
| uuid | 4.6.0 | MIT |
| vector_map_tiles | 8.0.0 | BSD-style |
| vector_math | 2.2.0 | BSD-style |
| vector_tile | 2.0.1 | MIT |
| vector_tile_renderer | 5.2.1 | BSD-style |
| vm_service | 15.2.0 | BSD-style |
| web | 1.1.1 | BSD-style |
| web_socket | 1.0.1 | BSD-style |
| web_socket_channel | 3.0.3 | BSD-style |
| webcrypto | 0.6.0 | Apache-2.0 |
| webpush_encryption | 1.0.1 | Apache-2.0 |
| win32 | 5.15.0 | BSD-style |
| window_manager | 0.5.2 | MIT |
| wkt_parser | 2.0.0 | MIT |
| xdg_directories | 1.1.0 | BSD-style |
| xml | 6.6.1 | MIT |
| yaml | 3.1.3 | MIT |
