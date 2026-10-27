# MiniMuses Play — Flutter iOS project

This ports the supplied Unity development preview into a native Flutter interface. It includes the character catalog, layered renderer, local character library and studio. The original Godot project's remaining feature gaps are listed below.

## Open and run on your Mac

Use Flutter **3.47.8** (the version used for validation), Xcode and CocoaPods. The project's minimum iOS deployment target is **15.5**.

1. Extract the complete ZIP. Open the **New-Muse-Flutter** folder containing `pubspec.yaml` in VS Code or Android Studio.
2. In its terminal, run:

```sh
flutter pub get
flutter run
```

Select an iPhone or iOS simulator. For Xcode, run `flutter build ios --config-only`, then `cd ios && pod install && cd ..` and open `ios/Runner.xcworkspace`. Choose your Apple signing team. This ZIP includes the real iOS project, workspace, Podfile, AppDelegate and SceneDelegate.

Swift Package Manager is disabled for this project and its generated-package references were removed from the Xcode project. Native plugins use CocoaPods. Do not copy plugins into `build/ios/SourcePackages` manually.

## Included

- Original 4,942 catalog entries in 92 categories, ten presets, 34 poses and rig geometry.
- All 29,186 artwork PNG layers and 28,463 thumbnail layers, loaded individually as Flutter assets.
- Character preview with tinting, affine limb transforms, basic eye/layer clipping, garment pieces and chest variants.
- Search/paging, colors and links, transforms, visibility, layer ordering, duplication, undo and redo.
- 200 character slots with automatic local saves and a backup file.
- Profile editing, custom presets, outfits and poses.
- Gzip character-code export; JSON, legacy gzip and MM2 import; clipboard and file sharing.
- Local PNG/JPEG import and transparent character PNG export.
- Studio with up to twelve actors, transforms, solid background, save/load and PNG export.
- Original credits and music. Music is converted to AAC/M4A for native iOS playback.
- Google Mobile Ads **9.2.0**, UMP consent checks, privacy options, foreground ad clock and bounded retries. No in-app purchases.

The interface supports phone portrait and landscape/tablet layouts. The preview temporarily hides when the keyboard leaves too little room for the editor.

## AdMob

**Google test ad units are enabled.** The AdMob app ID and interstitial production ID came from the supplied project. Confirm they belong to the intended app. The production rewarded ad unit ID is still missing.

The interstitial becomes eligible after **15 seconds of active foreground use** and is attempted at a tab transition. The optional rewarded button becomes eligible after **60 seconds**, subject to consent and ad availability. Earning the reward grants **120 active seconds without interstitials**. Dismissing an ad without earning its reward grants nothing. Background time, consent forms and full-screen ad time do not advance the clock.

To synchronize test settings:

```sh
python3 tool/configure_ads.py --test
```

Before production, supply your real rewarded ID (and override the other IDs if needed):

```sh
python3 tool/configure_ads.py --production --rewarded-id YOUR_IOS_REWARDED_ID
python3 tool/verify_project.py --release
```

The script updates both `assets/muse/ad-config.json` and `ios/Runner/Info.plist`. Edit these using the script so their app IDs stay synchronized. Test mode uses Google's sample **ad units**, with your configured app ID so UMP can use your app's Privacy & messaging configuration.

The original child-directed audience setting is retained, using the SDK's current age-restricted treatment API and G ad-content rating. Review that setting against your actual audience and configure your own AdMob Privacy & messaging forms. This port does not request tracking authorization.

## Validation and iOS release

See `VALIDATION.md` and `AssetValidation.json` for the checks performed. Repeat them with:

```sh
flutter analyze
flutter test
python3 tool/verify_project.py
```

Build an IPA on your Mac after setting signing and production configuration:

```sh
flutter build ipa --release
```

Use Xcode Organizer or Transporter to upload the signed build. Native CocoaPods resolution, Xcode compilation, actual device ad/consent presentation, sharing, audio, memory/performance and TestFlight upload still require Mac/device validation. No signed IPA or TestFlight upload is included.

## Known conversion limits

This carries over the supplied Unity preview's implemented features. It is not full Godot feature parity. The original animation/timeline editor, pattern shaders, multi-mask compositing, advanced body-fitting offsets, studio text/bubbles/background-image workflows and exact original intro/UI transitions remain unported. Thumbnail cards use one source layer instead of fully colored composites. Custom images stay local and are not embedded in character codes. Existing Godot/Unity save files are not automatically migrated; import character codes instead.

## Files

- `lib/main.dart`: Flutter screens and native file/share/audio integration.
- `lib/core.dart`: catalog, state, persistence and character codes.
- `lib/artwork.dart`: layered canvas renderer and PNG export.
- `lib/ads.dart`: consent, AdMob and ad clock.
- `assets/muse/`: original data, images, fonts and converted music.
- `ios/`: complete iOS host project.
- `test/`: state, rendering and UI workflow tests.

The source project's creator/supporter credits remain in Settings. Original assets retain their existing ownership and terms; this conversion grants no additional asset rights. Dependencies retain their own licenses.
