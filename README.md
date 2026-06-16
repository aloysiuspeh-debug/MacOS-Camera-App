# Camera

A small native macOS camera app built with AppKit and AVFoundation.

## Build

```sh
./scripts/build-app.sh
```

The script creates:

```text
dist/Camera.app
```

## Run

```sh
open dist/Camera.app
```

macOS will ask for camera permission the first time the app opens. The app shows a live camera preview, captures a JPEG photo, and opens a save panel for the snapshot.

## Installer

```sh
./scripts/build-installer.sh
open dist/Camera-1.0-Installer.pkg
```

The installer opens in Apple's Installer app and installs `Camera.app` into `/Applications`.
