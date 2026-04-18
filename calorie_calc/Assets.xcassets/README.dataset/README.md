# Calorie App Icon Set

Bold & modern blue flame-in-ring icon, rendered at all standard iOS app sizes plus web/PWA bonus sizes.

## Files included

### App Store
- `icon-AppStore-1024.png` — Required for App Store Connect submission

### iPhone
- `icon-iPhone-180.png` — Home screen @3x (iPhone 6+ and newer)
- `icon-iPhone-120.png` — Home screen @2x (older iPhones)

### iPad
- `icon-iPad-167.png` — iPad Pro
- `icon-iPad-152.png` — Standard iPad @2x

### Spotlight search
- `icon-Spotlight-120.png` — @3x
- `icon-Spotlight-80.png` — @2x

### Settings app
- `icon-Settings-87.png` — @3x
- `icon-Settings-58.png` — @2x

### Notifications
- `icon-Notification-60.png` — @3x
- `icon-Notification-40.png` — @2x

### Web & cross-platform (bonus)
- `icon-Web-512.png` — PWA manifest, marketing
- `icon-Web-192.png` — Android/PWA home screen
- `icon-Favicon-32.png` — Browser favicon

### Source
- `icon-master.svg` — Vector source. Edit this to produce new variations at any size.

## How to use in Xcode

1. Open your Xcode project
2. Go to `Assets.xcassets` → `AppIcon`
3. Drag each PNG into the matching slot (Xcode labels each slot with its point size and scale)
4. The 1024 PNG goes in the "App Store" slot

## Color palette

- Background gradient: `#1E6FD9` → `#5AB4FF` (top to bottom)
- Foreground: `#FFFFFF` (pure white)
- Ring background track: 30% white opacity

## Notes

- Icons are exported as solid rectangles (no pre-applied corner radius). iOS automatically applies the rounded-square mask on the home screen, so this is the correct format.
- The design uses only two colors plus a gradient, which keeps file sizes small and rendering crisp at every scale.
