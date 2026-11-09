# Watch Region

A standalone watchOS app that reads the MobileGestalt sales-region cache and applies `US / LL/A` to a supported `CH / CH/B` cache. The app saves and verifies the original bytes before writing, then verifies the in-place write. Restore Original requires a backup that matches the current cache. The app prompts you to wait 65 seconds before restarting and checks the cached values when you reopen it.

The earlier build was tested on an Apple Watch Ultra 4 running watchOS 27.3 beta (`24S5284h`). Support depends on the watchOS build and cache layout. The app changes two cached values. Siri AI availability also depends on Apple's eligibility checks, the paired iPhone, and Siri setup.

Use this tool only on a Watch you own or have permission to manage. It uses the `worse_query` sandbox escape to write a system cache. An incompatible change can cause instability or require a device restore.

## Build and install on your own Watch

1. Open `WatchRegion.xcodeproj` in Xcode 27 or later. Pair the Watch with your Mac in Device Hub and enable Developer Mode on the Watch and its companion iPhone.
2. In the WatchRegion target, select your development team and change the bundle ID to a unique identifier. In Signing & Capabilities, create and select a dedicated App Group for this app. In Build Settings, set `WATCH_REGION_APP_GROUP` to the same App Group ID. Check that the entitlement, built `WatchRegionAppGroup` value, and provisioning profile all use that ID. The group must have an empty `Library/Caches` directory because the underlying primitive temporarily replaces it with a symbolic link.
3. Select the physical Watch as the run destination and click Run. Open Watch Region and confirm it reads the expected sales region before applying or restoring.

[Pair devices with Xcode](https://developer.apple.com/documentation/xcode/pairing-your-devices-with-your-mac) · [Configure App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)

## Release asset

The release IPA contains the standalone watchOS app at `Payload/WatchRegion.app`. It is unsigned and needs a valid development or distribution signature and provisioning profile for your Watch before installation. The Xcode build instructions above configure those for your own development team. If signing the prebuilt app directly, set its `CFBundleIdentifier` and `WatchRegionAppGroup` in `Info.plist` to match the identity and dedicated App Group in your provisioning profile before signing.

To build the IPA with Xcode 27 or later, run `./Scripts/build-unsigned.sh` from the repository root. It writes the IPA and its SHA-256 checksum to `dist/`.

## License

GPL-3.0-or-later. The unchanged `worse_query` implementation is by Taj C (forcequit) and comes from [forcequitOS/worse_query at d1540e20](https://github.com/forcequitOS/worse_query/tree/d1540e20cd82b974d891e0551ced6d6aeb570ac2). See [LICENSE](LICENSE).

[GestaltX](https://github.com/huamidev/GestaltX) served as a reference for the region-editing workflow. This project does not incorporate GestaltX source code.
