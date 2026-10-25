# Roadmap

Status: planning. Milestones M0 to M8, labels and 29 issues exist at https://github.com/TheTractorHacker/openfamily/issues. The project board is not created yet (needs the `project` token scope).

| Milestone | Focus | First tasks |
|-----------|-------|-------------|
| M0 Repository Independence and Baseline Audit | Ownership, upstream refs, audits | Decide owner/repo name; replace `wheresfrank/openfamily` refs; init git with preserved history from upstream clone |
| M1 Security and Infrastructure Hardening | SEC-001..009 | Remove docker.sock updater, secret generation, pin images, scanners in CI |
| M2 Mobile Architecture and Design System | Flutter structure, tokens, a11y | Secure native credential storage (SEC-002) |
| M3 Family Circles and Accounts | Multi-circle schema, invites, roles | Authorization matrix tests, then schema migration |
| M4 Live Tracking and Maps | Tracking profiles, trips, history | Configurable retention (replace fixed 90 days) |
| M5 Notifications and Safety | Native push, SOS delivery states | Payloads without coordinates |
| M6 Life360-Inspired UX Redesign | Screens and flows | Needs the 15 Page Flows studied (not yet fetched) |
| M7 Production Deployment and Mobile Releases | Signed builds, release pipeline | Fork-independent release workflow |
| M8 Quality and Public Release | Load, battery, accessibility | Physical-device test procedures |

Optional: Dawarich export (design doc and issues first).

## Added from the upstream author's roadmap
- Adaptive, battery-aware tracking via activity recognition (#30, M4)
- Driving reports and trip summaries (#31, M4)
- Passkeys / WebAuthn (#32, M3)
- Crash detection with cancelable check-in (#33, M5)
- Design decision on end-to-end encryption vs server-side geofences (#34, M1)
