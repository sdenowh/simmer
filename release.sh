#!/bin/bash

# Simmer Release Script
# This script helps create a new release by building and tagging

set -e

echo "🚀 Simmer Release Script"
echo ""

# Check if version is provided
if [ $# -eq 0 ]; then
    echo "Error: Please provide a version number"
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.0.0"
    exit 1
fi

VERSION=$1

# Validate version format (simple check: must be like 1.0.0)
if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Invalid version format"
    echo "Please use semantic versioning (e.g., 1.0.0)"
    exit 1
fi

echo "📋 Release Checklist:"
echo "1. ✅ All changes committed to main branch"
echo "2. ✅ Tests passing"
echo "3. ✅ Version number: $VERSION"
echo ""

read -p "Are you ready to create release v$VERSION? (y/N): " -n 1 -r
echo
if ! [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Release cancelled"
    exit 0
fi

echo "🔨 Building app..."
./build.sh

echo "✅ Build successful!"

# Check if we're on main branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "⚠️  Warning: You're not on the main branch (currently on $CURRENT_BRANCH)"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if ! [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Release cancelled"
        exit 0
    fi
fi

# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Error: You have uncommitted changes"
    echo "Please commit or stash your changes before creating a release"
    git status --short
    exit 1
fi

echo "🏷️  Creating git tag v$VERSION..."
git tag v$VERSION

echo "📤 Pushing tag to GitHub..."
git push origin v$VERSION

echo "🎉 Release v$VERSION created successfully!"
echo
echo "Next steps:"
echo "1. GitHub Actions will automatically build and create a release"
echo "2. Check the Actions tab in your GitHub repository"
echo "3. The release will be available in your GitHub releases"
echo
echo "✨ Your Simmer app is ready for distribution!"