# Quotablet

Quotablet is a personal macOS app project for viewing the AI account usage limits reported by `omp usage`.

## Development status

This repository contains repository configuration and documentation. It does not yet contain an executable app.

The planned application uses SwiftUI for a menu bar panel and the locally installed OMP CLI as its data source. A WidgetKit extension can display the last collected snapshot. Quotablet does not need its own server. OMP may contact provider APIs or a configured authentication broker.

## Privacy

Keep authentication tokens, account identifiers, real usage snapshots, logs, and signing private keys out of this repository. Use synthetic accounts and values in examples, tests, and screenshots. Redacted CLI output can still reveal account prefixes and usage data.

Store local usage snapshots and logs under `.local/`, which Git ignores. Keep local Xcode settings in `Local.xcconfig`. Commit shared project settings and required entitlement declarations, but not signing certificates or provisioning profiles.

Ignore rules do not remove files that are already tracked. Review the files included in each commit before publishing.

## License

[MIT](LICENSE). Copyright 2026 chsong1.
