# Simmer

A macOS menubar application for iOS Simulator management, designed to make it easier to perform common iOS Simulator related tasks.

## ⚠️ Learning Project Warning

**This project is being used to learn how to code with Cursor AI. The code is what it is—a learning exercise that may contain bugs, inefficiencies, or unconventional patterns. This is not production-ready software and should not be used in critical environments.**

## Features

### 1. Simulator Management
- **List of recently used simulators** with detailed information
- Shows simulator name, iOS version, and device type icon
- Hierarchical menu structure for easy navigation
- Pin/unpin simulators for quick access

### 2. App Management
- **List of installed apps** for each simulator
- Displays app icons and names
- Click to access app-specific actions
- Automatic path validation and refresh when apps are reinstalled

### 3. Document Management
- **Show Documents Folder**: Opens the app's documents folder in Finder
- Shows the total size of the documents directory as a subtitle
- Automatic path validation to handle stale data after app reinstalls

### 4. Snapshot Management
- **Take Documents Snapshot**: Creates a backup of the current documents folder
- **Restore Snapshots**: Click on any existing snapshot to restore it with retry logic and validation
- **Delete Snapshots**: Individual snapshot deletion or bulk delete all
- Shows snapshot creation date and size information
- **Delete All Snapshots** shows total size of all snapshots as subtitle
- **Robust restore process** with automatic retry and validation

## Building the Application

### Prerequisites
- macOS 14.0 or later
- Xcode 15.0 or later
- iOS Simulator installed

### Quick Start
1. **Open the project in Xcode:**
   ```bash
   open Simmer.xcodeproj
   ```
2. **Build and Run** (⌘+R)
3. **The app will appear as an iPhone icon in your menubar**

### Alternative: Command Line Build
```bash
./build.sh
```

## Usage

1. **Launch**: The app will appear as an iPhone icon in your menubar.
2. **Click the menubar icon** to open the popover.
3. **Navigate the hierarchy:**
   - Click on a simulator to see its apps
   - Click on an app to see its actions
   - Use the actions to manage documents and snapshots

## Technical Details

### Architecture
- **SwiftUI** for the user interface
- **AppKit** for menubar integration
- **FileManager** for iOS Simulator data access
- **ObservableObject** for reactive state management

### Key Components
- `SimmerApp.swift`: Main application entry point and menubar setup
- `ContentView.swift`: Main UI with hierarchical menu structure
- `Models.swift`: Data models for simulators, apps, and snapshots
- `SimulatorService.swift`: Service layer for iOS Simulator interaction
- `Info.plist`: Menubar app configuration

### File Structure
```
Simmer/
├── Simmer.xcodeproj/         # Xcode project
├── Simmer/
│   ├── SimmerApp.swift        # Main app & menubar
│   ├── ContentView.swift      # UI components
│   ├── Models.swift           # Data models
│   ├── SimulatorService.swift # iOS Simulator service
│   ├── Info.plist            # App configuration
│   └── Assets.xcassets/      # App assets
├── Simmer-from-cursor/       # Original files from Cursor
├── build.sh                  # Build script
└── README.md                 # This file
```

## Permissions

The application requires access to:
- iOS Simulator data directory (`~/Library/Developer/CoreSimulator/Devices`)
- File system access for document management
- Finder integration for opening folders

## Development Notes

- The app is configured as a menubar-only application (`LSUIElement = true`)
- Uses `NSStatusItem` for menubar integration
- Implements hierarchical navigation with expandable/collapsible sections
- Provides real-time file size calculations for directories
- Handles iOS Simulator data structure parsing
- **Includes automatic path validation and refresh functionality** to handle stale data when apps are reinstalled during development

## Advanced Features

### Path Validation & Auto-Refresh
Simmer automatically detects when app paths become stale (e.g., after app reinstalls) and:
- Validates paths before every operation
- Automatically refreshes simulator data when needed
- Updates app references using bundle identifier matching
- Provides seamless recovery without user intervention

### Robust Snapshot Restore
The snapshot restore process includes:
- 0.5 second delay for file system completion
- Comprehensive validation comparing files between snapshot and restored state
- Automatic retry logic if validation fails
- Detailed progress tracking and user feedback

## Troubleshooting

### Common Issues
1. **No simulators found**: Ensure iOS Simulator is installed and has been used at least once
2. **Permission denied**: Grant necessary permissions in System Preferences > Security & Privacy
3. **App not appearing in menubar**: Check that the app is properly signed and has the correct entitlements
4. **Stale data after app reinstall**: The app now automatically detects and refreshes this—no manual intervention needed

### Debug Information
The application logs debug information to the console for:
- Simulator discovery
- App loading
- Snapshot operations
- File system errors
- Path validation and refresh operations

## License

This is a learning project—feel free to use, modify, or learn from the code as needed.

## Contributing

This is a personal learning project, but if you find bugs or have suggestions, feel free to open an issue or submit a pull request.

---

**Remember**: This is a learning project with Cursor AI. The code may contain bugs, inefficiencies, or unconventional patterns as part of the learning process. 