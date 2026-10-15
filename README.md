# BigNums

Menu bar spending tracker: `$today | $this week | $this month` across all connected Plaid accounts.

## Install
Download `BigNums-<version>.dmg` (or the `.zip`) from the Releases page and drag BigNums into Applications. It runs on macOS 14 or later, on Apple silicon and Intel Macs.

BigNums isn't signed with a paid Apple Developer ID, so **macOS shows a warning the first time**. This is expected and happens once:

1. Open BigNums from Applications. When macOS says it can't verify it, click **Done** (not "Move to Trash").
2. Open **System Settings → Privacy & Security**, scroll to the Security section, and click **Open Anyway** next to BigNums.
3. Open BigNums again and click **Open**.

Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/BigNums.app`

Then click the menu bar item → **Set up Plaid…** and paste your own keys (see below). The "Ask" assistant needs macOS 26 with Apple Intelligence; everything else works without it.

## Build from source
1. `./build.sh` (or `./build.sh --install` to copy into /Applications). It needs Xcode 26 or later and macOS 14 or later.
2. Click the menu bar item. On first run, **Set up Plaid…** opens Settings (⌘,).

### Bring your own Plaid keys
BigNums has no server and no shared account. You use your own Plaid account, so your keys and your bank data stay between your Mac and Plaid.

1. Create a free account at [Plaid](https://dashboard.plaid.com) and request production access (new teams get a free tier of 10 connected accounts; check Plaid's current plans).
2. In the dashboard, open **Developers → Keys** and copy your client ID and secret.
3. Paste them into BigNums → Settings → Plaid and press Save. They're checked with Plaid first.

Settings is also at ⌘, or the gear menu, and `open -a BigNums --args --settings` opens it directly. Your keys are stored in the macOS Keychain (this Mac only, not synced), never in a file or inside the app, and never in this repository. For development you can instead put `PLAID_CLIENT_ID`, `PLAID_SECRET` and `PLAID_ENV` in a `.env` next to the project: `./build.sh` moves them into the Keychain, and `swift run` reads them directly.

Click the menu bar item. It has three tabs along the bottom (⌘1–3):
- **Spend**: the period's total, with a lens switcher for merchants, categories, cards and a trend chart.
- **Bills**: recurring charges grouped by how soon each is due.
- **Balances**: net worth and every account with its balance. Add, reconnect or remove accounts here.

**Ask** (the sparkle button, or ⌘K) answers questions about your money in plain language, like "why is my spending up?" or "which bills are due this week?". It uses Apple's on-device model, so it needs macOS 26 and Apple Intelligence, and nothing leaves the Mac. The model never does the math: it calls tools that query your data, and every amount in an answer comes from them. Beyond lookups, an `insights` tool analyzes habits over past months: what to cut, impulse-spending patterns, trends, a budget with savings rate, subscriptions to cancel, and a close look at one merchant or kind of spending. Those need a few full months of history to say much, and they say so when there isn't. It can be switched off in the gear menu.

The gear menu holds settings (also on right-click of the menu bar item): show or hide the numbers, notify on new charges, refresh, quit.

## Making a release
`./build.sh --package` builds a universal (Apple silicon + Intel) release and writes `dist/BigNums-<version>.dmg`, `.zip` and `SHA256SUMS.txt`. The version comes from the `VERSION` file. It launches nothing, imports no keys, and refuses to package if a Plaid secret is found inside the app. Attach the files to a GitHub release (`gh release create v0.1.0 dist/*`).

## How totals are computed
- Sums outflows (`amount > 0`) from Plaid `/transactions/sync`, including pending.
- Skips transfers, credit card/loan payments and income (`personal_finance_category`), so paying your card from checking isn't double-counted.
- Uses the authorized date when available; week starts per your macOS locale.
- Refreshes every 15 min, when you open the menu, and about once a minute while it stays open.

Data (access tokens + recent transactions) lives in `~/Library/Application Support/BigNums/connections.json` (mode 600).

## Design review
Render the menu to a PNG without clicking the menu bar (debug builds only):
`BIGNUMS_SNAPSHOT=menu.png BIGNUMS_PERIOD=Week swift run` (add `BIGNUMS_DARK=1` for dark mode).
Pick what to render with `BIGNUMS_TAB=spend|bills|balances` and `BIGNUMS_LENS=merchants|categories|cards|trend`.
Add `BIGNUMS_REFRESH=1` to do a real sync first, so balances and other new data are current.
`BIGNUMS_INSIGHTS=1` prints the raw analysis behind the assistant's answers (useful for checking its numbers). `BIGNUMS_ASK_OPEN=1` shows the Ask screen, and `BIGNUMS_ASK='question|another'` asks the on-device model real questions first and prints the answers.

## License
MIT. See [LICENSE](LICENSE).
