# BigNums

A Mac menu bar app that shows what you spend today, this week and this month, using your own Plaid account.

## Install
1. Download the `.dmg` from [Releases](https://github.com/jaiamin/bignums/releases/latest) and drag BigNums into Applications. Needs macOS 14 or later.
2. The first time, macOS says it can't verify the app. Click **Done**, then open **System Settings → Privacy & Security** and click **Open Anyway**.
3. Click BigNums in your menu bar → **Set up Plaid…** and paste your keys.

## Plaid keys
BigNums has no server: you use your own free [Plaid](https://dashboard.plaid.com) account. Request production access, then copy your client ID and secret from **Developers → Keys** into BigNums → Settings (⌘,). They're stored in your Keychain.

## Build from source
`./build.sh` (needs Xcode 26+).

## License
MIT
