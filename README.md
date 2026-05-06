# IOSAppRewind

> Roll an iOS app back to an older App Store version when a new release breaks something you care about.

> ⚠️ **macOS only.** This project requires a MacBook or iMac. The sideload step depends on **Apple Configurator**, which is only available on the Mac App Store, and the helper scripts assume `bash` + Homebrew. Windows and Linux are not supported.

Sometimes a developer pushes an update to the App Store that you absolutely hate — a redesigned UI, a removed feature, a regression. The App Store doesn't let you downgrade, and once an app updates on your phone there's no in-OS way back. **IOSAppRewind is a pair of small Bash scripts that find and download any historical version of an iOS app**, so you can sideload it back onto your iPhone and carry on with your day.

It works because every previous build of an app remains addressable on Apple's servers via an internal `externalVersionId`. [`ipatool`](https://github.com/majd/ipatool) (signed in with your Apple ID) can purchase the licence and download the encrypted `.ipa`. AppRewind wraps `ipatool` to make that workflow ergonomic: search for the app, list every version, pick the one you want, download it. You then install the `.ipa` onto the device with **Apple Configurator**.

## Requirements
- macOS
- [HomeBrew](https://brew.sh/)
- [`ipatool`](https://github.com/majd/ipatool), `jq`, `curl`
- [Apple Configurator](https://apps.apple.com/app/apple-configurator-2/id1037126344) (free, Mac App Store)
- A Lightning / USB-C cable
- An Apple ID that has previously "purchased" (free is fine) the app you want to revert

## Setup

```bash
# Install dependencies with HomeBrew
brew install ipatool jq

# Authenticate ipatool with your Apple ID
ipatool auth login --email "you@example.com"

# Make the scripts executable
chmod +x install_ipa.sh search_apps.sh
```

## Usage

### 1. Find the app's `app_id`

```bash
./search_apps.sh "Facebook"
./search_apps.sh --query "Facebook,Whatsapp"   # comma-separated runs multiple searches
```

You'll get a pretty list with App ID, Bundle ID, version, genre, seller, rating, size, and a truncated description. For example:

```
─────────────────────────────────────────────────────────────
📱 Facebook
─────────────────────────────────────────────────────────────
  App ID      : 284882215
  Bundle ID   : com.facebook.Facebook
  Version     : 560.1
  Price       : 0
  Genre       : Social Networking
  Seller      : Meta Platforms, Inc.
  Rating      : 4.52
  Size        : 435 MB
  Description : Where real people propel your curiosity. Whether you're thrifting gear, showing reels to that group who gets it, or sharing laughs over fun ...

─────────────────────────────────────────────────────────────
📱 WhatsApp Messenger
─────────────────────────────────────────────────────────────
  App ID      : 310633997
  Bundle ID   : net.whatsapp.WhatsApp
  Version     : 26.17.72
  Price       : 0
  Genre       : Social Networking
  Seller      : WhatsApp Inc.
  Rating      : 4.69
  Size        : 330 MB
  Description : WhatsApp from Meta is a free messaging and calling app used by over 2 billion people across 180+ countries. It's super simple, reliable and ...
```

**Copy the `App ID`** of the app you want to revert — you'll pass it to `install_ipa.sh` in the next step.

### 2. List every available version

```bash
./install_ipa.sh --app-id 1530411160
```

This fetches every historical build in parallel and caches the result in `./.cache/versions.json` so subsequent runs are instant. Output looks like:

```
ID: 873356668 -> 5.1.170
ID: 884821166 -> 5.8.170
ID: 885302351 -> 5.8.200
...
```

### 3. Download the version you want

```bash
# Either by version string…
./install_ipa.sh --app-id 1530411160 --version "5.1.170"

# …or by external id from the list above
./install_ipa.sh --app-id 1530411160 --id 873356668

# Once an app is in the cache, --app-id is optional
./install_ipa.sh --version "5.1.170"
./install_ipa.sh --id 873356668
```

The `.ipa` lands in `./.output/`. Use `--refresh` to bypass the cache and re-fetch from Apple, and `--output-folder PATH` to override the destination.

## Installing the `.ipa` on your iPhone

> ✅ **No signing hassle.** The `.ipa` you downloaded is the *official* build from Apple's servers, already signed by the developer. Apple Configurator installs it directly under your Apple ID — there are **no certificates to manage, no resigning, no 7-day re-signing every week, no developer account, works worldwide, and no jailbreak**. None of the usual sideloading hurdles you'd hit with example **AltStore / SideStore / Sideloadly**.

1. **Install Apple Configurator** from the Mac App Store (free).
2. **Connect your iPhone** to your Mac with a cable. On the iPhone, tap **Trust This Computer** the first time you connect (you may need to enter your passcode).
3. In Apple Configurator, select your iPhone, then in the top menu bar choose **Actions → Add → Apps…** (or click the **+** button in the window's toolbar and pick *Apps*).
4. Click **Choose from my Mac…** and select the `.ipa` from `./.output/`.
5. You'll be prompted with **"The app named 'XXX' already exists on 'iPhone…'"**. Choose **Replace** — this is the recommended option because it keeps all of the app's existing data (logins, settings, local files) intact while swapping the binary for the older version.

That's it — the older build is now on your phone.

> ⚠️ Disable automatic updates for the app (Settings → App Store → App Updates) or the App Store will silently re-update it back to the version you didn't want.

## Caching
After the first list run for an app, every subsequent `--version` / `--id` lookup hits the cache and skips the slow `ipatool list-versions` + per-version metadata calls entirely. Each app you list is appended; existing apps are kept on cache writes.

## Troubleshooting

- **"Not signed in to ipatool"** — run `ipatool auth login --email <APPLE_ID>`. Sign out with `ipatool auth revoke`.
- **"Version X not found for App ID Y"** — your cache may be stale. Run with `--refresh`.
- **"Zip Reader" / corrupted `.ipa`** — usually a leftover from a prior failed download. The script removes the existing file before each download to prevent this; if it still happens, delete the file in `./.output/` manually and retry.
- **Apple Configurator says the app isn't signed for this device** — the Apple ID in `ipatool` must match the Apple ID that originally acquired the app. Sign in with that same account.
