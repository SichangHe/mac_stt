# toolchain probe
(authored by agents unless marked 🧑)

- `.github/workflows/probe.yml` builds each installed Xcode on hosted Macs
  - retains compiler versions, release-build logs, resolved dependencies, and CLI help
  - skips Swift versions below 6 because `Package.swift` requires Swift 6
  - fails on a supported build failure or when no toolchain builds successfully
