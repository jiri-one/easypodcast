# EasyPodcast app

Flutter client for Android and Linux, built for e-ink screens. See the [root README](../README.md) for the feature list and full self-hosting guide.

## Requirements

- Flutter `3.50.1` (Dart SDK `^3.14.0`)
- **Android**: Android SDK, JDK 17, and GNU `patch` (Gradle applies `android/audio_service.patch` during the build)
- **Linux**: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libmpv-dev`

## Build

Install dependencies first:

```sh
flutter pub get
```

### Android

For a release APK signed with your own key, place your keystore under `android/` and create `android/key.properties` (`chmod 600`, ignored by Git):

```properties
storePassword=...
keyPassword=...
keyAlias=easypodcast
storeFile=easypodcast.jks
```

Then build:

```sh
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`. Without `android/key.properties`, release builds fall back to the Android debug signing key. For a debug build, run `flutter build apk --debug` (`build/app/outputs/flutter-apk/app-debug.apk`).

Sideloaded APKs require enabling **Unknown sources** in Android Auto developer settings to appear in Android Auto.

### Linux

```sh
flutter build linux --release
```

Output: a relocatable bundle in `build/linux/x64/release/bundle/` (or `arm64` on ARM64 Linux) containing the `easypodcast` executable, `share/applications/one.jiri.easypodcast.desktop`, and icons under `share/icons/`.

## Tests

```sh
flutter analyze
flutter test
```

On Linux, after `flutter build linux --release`, run the native desktop font parser test:

```sh
cmake -S linux -B build/linux/x64/release -DBUILD_TESTING=ON
cmake --build build/linux/x64/release --target desktop_font_test
ctest --test-dir build/linux/x64/release --output-on-failure
```

To run the client-server integration suite in `integration_test_server/` against a local server, use `../tools/e2e-server.sh --test` (see the [root README](../README.md#running-tests) for prerequisites).
