# Validation results

Validated with **Flutter 3.47.8 / Dart 3.13.7** on Linux.

- `flutter analyze --no-pub`: **No issues found**.
- `flutter test --no-pub --reporter expanded`: **9 tests passed**.
- Core tests cover retained catalog counts, equipment changes, undo/redo, save/reopen across slots, legacy gzip/MM2 character-code import, malformed/oversized import rejection, linked colors, duplication/removal, poses and independent studio snapshots.
- The ad-clock test covers the 10-second first interstitial, 30-second repeat interval and 60-second reward threshold, background pause, full-screen overlap prevention, no reward from dismissal and earned ad-free time.
- The renderer test decoded and rendered all ten presets through Flutter's real canvas/image engine and exported PNGs. It also checked two-actor studio composition and actor ordering.
- The widget workflow exercised wardrobe equipment, the color dialog, layer controls, slot switching, adding a second studio actor and saving/reopening UI state. Phone (390 × 844) and landscape (1280 × 900) layouts were checked without framework exceptions. The test loads the app's real font and Material icon font for screenshots.
- A dialog-controller lifetime bug found by this workflow was fixed by retaining controllers until the closing route transition completes. The final complete test run passed after the fix.
- `tool/verify_project.py`: all **29,186 artwork** and **28,463 thumbnail** files passed presence, length, PNG signature, dimensions and PNG chunk CRC checks.
- The Xcode project parsed as an OpenStep property list, and all 56 project-object references resolved. iOS plists and the scheme parsed. The bundled project has no generated Swift Package Manager references.
- The ZIP's complete CRC check passed, and the project entry point, pubspec, dependency lockfile and iOS workspace are included.

## Still requiring Mac/device checks

CocoaPods resolution, Xcode/Swift/Objective-C compilation, signed iOS installation, native file picker/share sheet, music playback, actual AdMob/UMP presentation, memory/performance and TestFlight upload have not been performed here. Widget tests do not validate those native SDK flows.

CAS.AI test ads are enabled by default. Native CocoaPods resolution and Xcode compilation still require Mac validation.

The files in `Previews` were rendered by Flutter during testing; they are not mockups.
