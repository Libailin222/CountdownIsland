#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/module-cache CountdownIsland.app/Contents/MacOS CountdownIsland.app/Contents/Resources
xcrun swiftc -O -swift-version 5 -module-cache-path .build/module-cache main.swift -o CountdownIsland.app/Contents/MacOS/CountdownIsland -framework AppKit -framework SwiftUI -framework Combine
cp Info.plist CountdownIsland.app/Contents/Info.plist
cp AppIcon.icns CountdownIsland.app/Contents/Resources/AppIcon.icns
codesign --force --sign - CountdownIsland.app
