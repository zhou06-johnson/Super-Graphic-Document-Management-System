# MemoirsCore iOS / Flutter

This directory contains the Flutter client. The native iOS wrapper is under
`ios/`; Dart screens and services are under `lib/`.

## Run on an iOS simulator

Use a Mac with Xcode, a Flutter SDK compatible with the Dart SDK constraint in
`pubspec.yaml`, and CocoaPods installed. From this directory run:

```sh
flutter doctor
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace
```

Select an iPhone simulator in Xcode and press Run, or use:

```sh
flutter devices
flutter run -d <device-id>
```

The first `flutter pub get` regenerates the Flutter/Xcode files that were
machine-specific in the supplied archive. Do not restore the old generated
`ios/Flutter/Generated.xcconfig` or plugin registrant files from that archive.

## Connect the API

The app opens without a backend and shows an empty or cached home feed. To use
server-backed features, start the Python backend in `../backend` and set its
address in the app's gear menu.

- iOS simulator: `http://127.0.0.1:8000`
- Android emulator: `http://10.0.2.2:8000`
- Physical iPhone: `http://<Mac-LAN-IP>:8000`; connect both devices to the same
  Wi-Fi and allow local network access when iOS asks.

The setting is saved locally and survives app restarts. The app also caches the
latest home card metadata in its Application Support directory, so the home feed
can still be viewed without a network connection. Photo files remain on the
backend and are not copied into this cache.

For a one-off build, the API URL can also be supplied with
`--dart-define=API_BASE_URL=http://192.168.1.20:8000`.

See `../FILE_GUIDE.md` for the purpose of every delivered source/configuration
file and `../README.md` for backend setup.
