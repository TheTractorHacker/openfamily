# Credits and license

Orbitly is a free, open-source fork of OpenFamily, licensed AGPL-3.0; who built it, what it is based on and where to get the source.

## Where Orbitly comes from

**Orbitly is a substantially extended fork of
[OpenFamily](https://github.com/wheresfrank/openfamily) by wheresfrank and
contributors.** Thank you to the original authors: the first version of the
server, the app and the idea of a private, self-hosted way to share locations
came from their work. Orbitly was published as "OpenFamily" until the rename
to Orbitly; it is the same project and the same code history, nothing was
re-started.

The name changed because the project is for any circle of people, family and
friends alike, and because several unrelated projects are also called
OpenFamily.

## License

Orbitly is free software under the **GNU Affero General Public License,
version 3** (AGPL-3.0). The full text is in [LICENSE](../../LICENSE) in the
repository. You may use, study, change and share it, and if you share a
changed version (or run one for other people as a service) you must offer them
its source under the same license.

The copyright notices of the original OpenFamily authors are kept; changes and
additions belong to their respective contributors. See [NOTICE](../../NOTICE).

## Source code (AGPL section 13)

Everyone who uses an Orbitly server over a network may get the source of the
version it runs. The public source is
<https://github.com/TheTractorHacker/orbitly> (the address the old
`TheTractorHacker/openfamily` name redirects to). Check out the tag that your
server reports under Settings, About. If you run a **modified** version, you
must publish your modified source and point your users to it: change the links
in `app/lib/brand.dart` and `web/src/lib/brand.ts` before you build.

You can find these credits and links inside the products:

- the app: **Settings, About**, with the open-source licenses page;
- the admin web: the footer of every page, the sign-in page, and
  **Settings, About Orbitly**.

## Third-party code

- [background_locator_2](https://pub.dev/packages/background_locator_2)
  (MIT; Copyright 2020 REKAB, Copyright 2022 Yukams): a modified copy is
  vendored under `app/packages/background_locator_2` and keeps its own
  `LICENSE`.
- Every Go, npm and Dart dependency and its license is listed in
  [Third-party licenses](../THIRD_PARTY_LICENSES.md); the audit is in
  [License compliance](../LICENSE_COMPLIANCE.md).
- Map data is from OpenStreetMap contributors (ODbL).

## Names that still say "openfamily"

Some internal identifiers keep the old spelling on purpose so existing
installs keep updating. See [Naming](../developers/naming.md).
