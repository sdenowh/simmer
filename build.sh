#!/bin/bash

echo "Building Simmer menubar application..."

# Navigate to the project directory
cd Simmer

# Build the project
xcodebuild -project Simmer.xcodeproj -scheme Simmer -configuration Debug build

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo "🚀 You can now run the app from Xcode or find it in the build products directory."
    echo ""
    echo "To run from Xcode:"
    echo "1. Open Simmer.xcodeproj in Xcode"
    echo "2. Press ⌘+R to build and run"
    echo ""
    echo "The app will appear as an iPhone icon in your menubar."
else
    echo "❌ Build failed. Please check the error messages above."
fi 