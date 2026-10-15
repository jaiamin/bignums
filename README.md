# BigNums

Menu bar spending tracker: `$today | $this week | $this month` across all connected Plaid accounts.

## Run
1. Fill in `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV` in `.env`.
2. `./build.sh` (or `./build.sh --install` to copy into /Applications). Re-run after any code or `.env` change.

Click the menu bar item. It has three tabs along the bottom (⌘1–3):
- **Spend**: the period's total, with a lens switcher for merchants, categories, cards and a trend chart.
- **Bills**: recurring charges grouped by how soon each is due.
- **Balances**: net worth and every account with its balance. Add, reconnect or remove accounts here.

The gear menu holds settings (also on right-click of the menu bar item): show or hide the numbers, notify on new charges, refresh, quit.

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
