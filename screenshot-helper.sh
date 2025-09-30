#!/bin/bash

# Screenshot Helper Script for Simmer
# This script helps enable mock data and take screenshots for marketing

echo "📸 Simmer Screenshot Helper"
echo ""

echo "This script will:"
echo "1. Enable mock data in Simmer"
echo "2. Launch Simmer with mock data"
echo "3. Provide instructions for taking screenshots"
echo ""

read -p "Continue? (y/N): " -n 1 -r
echo

if ! [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 0
fi

# Enable mock data
echo "🔧 Enabling mock data..."
defaults write com.simmer.app UseMockData -bool true

echo "✅ Mock data enabled!"
echo ""
echo "📱 Next steps:"
echo "1. Launch Simmer (if not already running)"
echo "2. Press ⌘+M to toggle mock data if needed"
echo "3. Take screenshots of the app with mock data"
echo ""
echo "📋 Suggested screenshots:"
echo "- Main simulator list (shows iPhone 15 Pro, iPad Pro, etc.)"
echo "- App list for a simulator (shows Instagram, TikTok, etc.)"
echo "- Snapshots for an app (shows backup snapshots)"
echo "- Document sizes and snapshot management"
echo ""
echo "🎯 To disable mock data later:"
echo "- Press ⌘+M in Simmer, or"
echo "- Run: defaults write com.simmer.app UseMockData -bool false"
echo ""
echo "✨ Ready for screenshots!" 