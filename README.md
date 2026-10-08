# BigNums

Menu bar spending tracker: `$today | $this week | $this month` across all connected Plaid accounts.

## Run
1. Fill in `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV` in `.env`.
2. `./build.sh` (or `./build.sh --install` to copy into /Applications). Re-run after any code or `.env` change.

Click the menu bar item to see totals, add a connection (opens Plaid Hosted Link in your browser), or remove one.

## How totals are computed
- Sums outflows (`amount > 0`) from Plaid `/transactions/sync`, including pending.
- Skips transfers, credit card/loan payments and income (`personal_finance_category`), so paying your card from checking isn't double-counted.
- Uses the authorized date when available; week starts per your macOS locale.
- Refreshes every 15 min and when you open the menu.

Data (access tokens + recent transactions) lives in `~/Library/Application Support/BigNums/connections.json` (mode 600).

## Design review
Render the menu to a PNG without clicking the menu bar (debug builds only):
`BIGNUMS_SNAPSHOT=menu.png BIGNUMS_PERIOD=Week swift run` (add `BIGNUMS_DARK=1` for dark mode).
