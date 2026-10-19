# Gaming DNS Manager

Flutter Android app for importing, validating, testing and managing DNS resolver addresses, with a local SQLite inventory and a DNS-only Android `VpnService` tunnel.

## Features

- SQLite-backed inventory with paged display and duplicate prevention
- User-configurable DNS import count from public sources and TXT/CSV/JSON files
- Single DNS testing and page-wise DNS testing with actual DNS queries
- Delete invalid addresses, unresponsive tested DNS entries, slow DNS entries by latency threshold, selected entries, or the entire inventory
- IPv4-mapped IPv6 and well-known NAT64 representation converter; reverse conversion only for recognized formats
- Local DNS-only VPN tunnel using Android `VpnService`; it does not change the public IP and does not tunnel ordinary Internet traffic
- GitHub Actions release APK workflow with pinned Flutter and diagnostic artifacts

## Build on GitHub

**Use the repository root layout in this ZIP.** Do not upload a ZIP as one file and do not nest the project in another `dns-main/` directory. See [BUILD.md](BUILD.md) for exact migration instructions. Remove old workflows under `.github/workflows/`, then run **Gaming DNS Android Build v5**. A successful run uploads `Gaming-DNS-Release-APK-v5`; a failed run uploads `Gaming-DNS-Build-Logs-v5`.

## Important DNS limitations

An address appearing in a public list does not prove it is currently reachable or suitable for a game. DNS response latency is not the same as game-server ping. IPv4 can only be converted into defined IPv6 representations such as IPv4-mapped or NAT64; an arbitrary native IPv6 address has no unique IPv4 equivalent. The local tunnel forwards DNS requests on UDP/TCP port 53 only; it is not a full VPN and does not override apps using their own DNS-over-HTTPS implementation.

For complete build and testing notes, see [BUILD.md](BUILD.md).
