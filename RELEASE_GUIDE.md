# GitHub Actions Release Guide for Simmer

This guide explains how to use GitHub Actions to automatically build and release new versions of the Simmer macOS app.

## Overview

The GitHub Actions workflows in this repository provide automated building and releasing of the Simmer app. There are two main workflows:

1. **Build Workflow** (`.github/workflows/build.yml`) - Builds the app on every push and pull request
2. **Release Workflow** (`.github/workflows/release.yml`) - Creates releases when you push tags

**Note**: The `.github` directory is located in the `Simmer` directory where the git repository is located.

## How to Create a Release

### Method 1: Using Git Tags (Recommended)

1. **Make your changes** and commit them to the main branch
2. **Create and push a tag** with a version number:
   ```bash
   git tag v1.0.0
   git push origin v1003e release workflow will automatically:**
   - Build the app in Release configuration
   - Create a `.app` bundle
   - Create a `.dmg` file for distribution
   - Create a GitHub release with the DMG file attached
   - Generate release notes based on the template

### Method 2 Workflow Dispatch

1. Go to the **Actions** tab in your GitHub repository
2. Select the **Build Simmer** workflow
3. Click **Run workflow**
4. Choose the branch and click **Run workflow**

## Workflow Details

### Build Process

The build workflow performs these steps:

1. **Setup Environment**
   - Uses macOS latest runner
   - Installs Xcode 15
   - Caches Xcode derived data for faster builds

2. **Build the App**
   ```bash
   xcodebuild -project Simmer.xcodeproj \
     -scheme Simmer \
     -configuration Release \
     -derivedDataPath build \
     build
   ```
3. **Create App Bundle**
   - Creates the proper `.app` structure
   - Copies the built binary to `Contents/MacOS/`
   - Copies `Info.plist` to `Contents/`
   - Copies assets to `Contents/Resources/`
   - Makes the binary executable
4. **Create DMG**
   - Creates a compressed DMG file for distribution
   - Uses `hdiutil` to create the disk image
5. **Upload Artifacts**
   - Saves both `.app` and `.dmg` files as workflow artifacts

### Release Process

When a tag is pushed, the release workflow:

1. **Downloads artifacts** from the build job
2. **Creates a GitHub release** with:
   - Release notes template
   - DMG file attached for download
   - App bundle for direct installation

## Release Notes Template

The release workflow automatically generates release notes including:

- **WhatsNew** section
- **Installation instructions**
- **Feature overview**
- **System requirements**
- **Permissions needed**
- **Troubleshooting guide**

## File Structure Created

```
Simmer/
├── Simmer.app/           # macOS app bundle
│   ├── Contents/
│   │   ├── MacOS/
│   │   │   └── Simmer    # Executable binary
│   │   ├── Resources/
│   │   │   └── Assets.xcassets/
│   │   └── Info.plist
└── Simmer.dmg           # Distribution disk image
```

## Versioning

Use semantic versioning for your tags:
- `v1.0.0` - Major release
- `v1.1.0` Minor release with new features
- `v1.0.1` Patch release with bug fixes

## Troubleshooting

### Build Failures
1. **Check Xcode version compatibility**
   - Ensure your local Xcode version matches the workflow (15.0). Update the workflow if needed

2. **Verify project structure**
   - Ensure `Simmer.xcodeproj` exists
   - Check that the `Simmer` scheme is available

3. **Check for missing files**
   - Ensure `Info.plist` exists
   - Verify assets are in the correct location

### Release Issues

1. **Tag format**
   - Tags must start with `v` (e.g., `v1.0.0`)
   - Use semantic versioning

2. **GitHub permissions**
   - Ensure the workflow has permission to create releases
   - Check that `GITHUB_TOKEN` is available

3. **Artifact download**
   - Verify the build job completed successfully
   - Check that artifacts were uploaded correctly

## Local Testing

Before pushing a release, test the build locally:

```bash
cd Simmer
./build.sh
```

This will build the app locally and help identify any issues before the GitHub Actions run.

## Customization

### Modifying Build Configuration

Edit `.github/workflows/build.yml` to:
- Change Xcode version
- Add additional build steps
- Modify artifact paths

### Customizing Release Notes

Edit the `body` section in `.github/workflows/release.yml` to:
- Update feature descriptions
- Add installation instructions
- Include changelog information

### Adding Code Signing

To add code signing for distribution:

1. Add your developer certificate to GitHub Secrets
2. Modify the build steps to include signing
3. Update the release workflow to handle signed builds

## Security Considerations

- The app is built in Release configuration for optimal performance
- No sensitive data is included in the build artifacts
- The workflow uses GitHub's built-in security features

## Support

If you encounter issues with the GitHub Actions workflows:

1. Check the **Actions** tab for detailed logs
2. Verify your repository has the necessary permissions
3. Ensure your Xcode project structure matches the workflow expectations

For more information about the Simmer app, see the main [README.md](README.md). 