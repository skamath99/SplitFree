# SplitFree

A completely free iOS Splitwise alternative. Every feature Splitwise puts behind
its Pro subscription is free here — no ads, no accounts, no servers.

<p>
<img src="screenshots/03-group-detail.png" width="200">
<img src="screenshots/05-settle-up.png" width="200">
<img src="screenshots/06-insights.png" width="200">
</p>

## Features

**Core (what Splitwise gives free):** groups, expenses, equal/exact/percentage/shares
splits, running balances, debt simplification (min-cash-flow: the fewest possible
payments), recorded settlements, recurring expenses.

**The paywalled stuff, free:**

| Splitwise Pro feature | SplitFree implementation |
|---|---|
| Receipt scanning | On-device Vision OCR; photo never leaves the phone |
| Currency conversion | 30 currencies with bundled offline rates |
| Itemization | Per-line-item splits; tax/tip spread proportionally |
| Expense search | Full search across all groups (Activity tab) |
| Charts | Swift Charts monthly + category breakdowns (Insights tab) |
| Ad-free | There are no ads to remove |

## Architecture decisions

**Why no in-app Apple Pay button.** Apple exposes no public API for sending
person-to-person Apple Cash payments — PassKit is for paying *merchants* and
requires a payment processor. So no app can move P2P money for free. SplitFree
does the next-best serverless thing: **"Pay in Messages"** opens iMessage with
the amount pre-filled (`sms:` URL), where Apple Cash is built into the keyboard,
and you record the settlement in the app.

**Why no database server.** Everything is SwiftData on-device. The models follow
CloudKit's compatibility rules (no unique constraints, optional inverse
relationships, defaults everywhere), so the upgrade path to **CloudKit** — Apple's
free hosted storage, the "Game Center for data" — is a one-line
`ModelConfiguration(cloudKitDatabase: .private(...))` plus the iCloud entitlement.
Shared groups between users would use `CKShare` on the same infrastructure.
Still no third-party servers, ever.

**Money math.** All amounts are integer minor units (cents). Splits use
largest-remainder allocation so every penny is accounted for deterministically.
Debt simplification is greedy min-cash-flow (largest debtor ↔ largest creditor),
guaranteeing ≤ n−1 transfers.

## Project layout

- `SplitCore/` — pure Swift package: `Money`, `SplitCalculator`, `DebtSimplifier`,
  `Ledger`, `CurrencyConverter`. Unit-tested (`swift test`, 17 tests).
- `App/` — SwiftUI app: SwiftData models + views (groups, expense form with all
  split modes and itemization, settle up, activity search, insights charts,
  receipt scanner).
- `UITests/` — XCUITest end-to-end flow (create group → split → settle → persist
  across relaunch) plus a screenshot tour.

## Building

```sh
brew install xcodegen   # once
xcodegen generate
xcodebuild -project SplitFree.xcodeproj -scheme SplitFree \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Unit tests: `cd SplitCore && swift test`. UI tests: `xcodebuild test` with the
same scheme.

## Roadmap

- CloudKit sync + `CKShare` group sharing (models are ready)
- Live exchange rates (optional network fetch, still no server)
- Expense detail view with per-person breakdown
- Widgets / App Intents ("Add expense" from the Home Screen)
