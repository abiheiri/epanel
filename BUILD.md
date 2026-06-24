# Building ePanel

## macOS

### Option 1: Homebrew

```bash
brew install cmake qt@6
```

Build:

```bash
cd /path/to/epanel_cpp
cmake -B build -S . \
    -DCMAKE_PREFIX_PATH=$(brew --prefix qt@6) \
    -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

### Option 2: Self-contained install with aqtinstall

This is the method used during development. It downloads Qt into the project directory without touching system paths.

```bash
cd /path/to/epanel_cpp
python3 -m venv .venv
source .venv/bin/activate
pip install aqtinstall

# List available versions: aqt list-qt mac desktop
aqt install-qt mac desktop 6.12.0 clang_64 -O .qt/6.12.0/macos

cmake -B build -S . \
    -DCMAKE_PREFIX_PATH=/path/to/epanel_cpp/.qt/6.12.0/macos/6.12.0/macos \
    -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

If you installed Qt via the online installer instead, use the path to that installation, e.g. `~/Qt/6.12.0/macos`.

The result is `build/epanel.app`.

## Linux (Debian/Ubuntu)

Install Qt 6, CMake, and a compiler:

```bash
sudo apt update
sudo apt install cmake build-essential qt6-base-dev qt6-base-dev-tools libqt6network6-dev
```

Then build:

```bash
cd /path/to/epanel_cpp
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Run with `./build/epanel`.

## Windows

Install Qt 6 and CMake (for example via the [Qt Online Installer](https://www.qt.io/download-qt-installer)), then open a Qt-enabled command prompt or MSVC prompt:

```cmd
cd C:\path\to\epanel_cpp
cmake -B build -S . -DCMAKE_PREFIX_PATH=C:\Qt\6.12.0\msvc2019_64 -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

Run `build\Release\epanel.exe`.

## Notes

- Qt 6 Widgets, Core, Gui, and Network are required.
- The local development build used a self-contained Qt installed at:
  `/Users/al/Documents/epanel_cpp/.qt/6.12.0/macos/6.12.0/macos`. That path is specific to the development machine and is not committed.
