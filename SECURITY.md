# Security

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a security problem.

Use a [private GitHub security advisory](https://github.com/TheTractorHacker/openfamily/security/advisories/new)
on this repository, or email the maintainer at the address on their GitHub
profile.

Include:

- Affected version or commit
- What an attacker would need (account, network, physical device)
- Steps to reproduce
- Impact (location leak, account takeover, etc.)

We will acknowledge the report and work on a fix before any public write-up.

## Deployment baseline

A public instance should set `APP_ENV=production`, a 32+ byte `JWT_SECRET`,
TLS (Caddy), invite-gated registration (`PLATFORM_ADMIN_EMAIL`), and must not
publish ntfy on `0.0.0.0`. Details: [docs/self-hosting.md](docs/self-hosting.md).
