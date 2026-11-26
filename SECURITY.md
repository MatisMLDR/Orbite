# Security

## What runs with privileges

Orbite itself runs as your user. For real domain names, it can install an optional helper, `OrbiteHelper`, as a launch daemon with `SMAppService`; macOS asks for an admin approval first. The helper runs as root because capturing packets requires it, and does only this:

- It captures DNS answers (UDP port 53) on the active interfaces with `libpcap`, not in promiscuous mode, and keeps the answers that match a query this Mac sent.
- It keeps them in memory only (at most 50,000 entries), writes nothing to disk and makes no network request.
- It exposes a read-only XPC service: its version, the DNS answers it saw, its capture status, and a way to quit so launchd restarts it after an update.
- It accepts connections only from Orbite, signed by the same team, and Orbite only trusts a helper signed by that team. Both check the other's code signature.

You can turn the helper off in Orbite's settings (Domain Names) or in System Settings › General › Login Items & Extensions.

## Reporting a vulnerability

Please report security issues privately through [GitHub's private vulnerability reporting](https://github.com/MatisMLDR/Orbite/security/advisories/new) rather than in a public issue. Include the steps to reproduce and the version of Orbite and macOS. You will get an answer within a week.
