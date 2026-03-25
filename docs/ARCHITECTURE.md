# Kharcha — Architecture

A native iOS app for capturing bill photos, optionally annotating them, and syncing to Google Sheets + Drive.

## Target

- iOS 26+, Swift 6.2, Xcode 26.3
- SPM dependencies: GRDB (SQLite), GoogleSignIn-iOS
- No other third-party dependencies. All other functionality uses system frameworks.

## Core Flow

```
take photo / pick from library
  → resize to max 2048px, compress JPEG 0.80
  → save image to disk (Documents/bill_images/)
  → insert SQLite row as 'draft' (image path + created_at)
  → kick off Vision OCR in background → update rawText in DB when done
  → navigate to review screen

review screen
  → show image + editable fields (vendor, date, amount, currency, GST, GSTIN, bill no)
  → form disabled until OCR finishes (polls DB for rawText, 15s timeout)
  → form disabled if bill is already uploaded
  → user fills in fields manually, taps Save → status becomes 'saved'

sync (background)
  → triggered on: save, app foreground, network reachability change
  → for each bill with status 'saved':
      1. upload image to Google Drive (resumable upload) — skipped if driveURL already set
      2. append row to Google Sheet (Sheets API v4)
      3. mark status 'uploaded'
  → errors surface in a red banner on the bills list with retry button
```

## Status Machine

```
draft → saved → uploaded
```

- `draft`: image captured, OCR may be in progress, user hasn't confirmed fields
- `saved`: user confirmed, pending sync
- `uploaded`: synced to Drive + Sheets. Form becomes read-only.

Re-editing an uploaded bill is not allowed.

## Project Structure

```
Kharcha/
├── App.swift                    # Entry point, service wiring, tab view, first-run routing
├── Models/
│   ├── Bill.swift               # GRDB Record — id, imagePath, vendor, date, amount, currency,
│   │                            #   gstAmount, gstin, billNo, rawText, status, driveURL, timestamps
│   └── Currency.swift           # Enum: INR, USD, EUR, GBP, ZAR, KRW, JPY, CAD, ISK
├── Services/
│   ├── CameraService.swift      # PHPickerViewController (library) + UIImagePickerController (camera)
│   ├── DatabaseService.swift    # GRDB: migrations, CRUD, search, pending sync query
│   ├── GoogleAuthService.swift  # Google Sign-In: sign in/out, token refresh, scopes
│   ├── OCRService.swift         # Apple Vision: VNRecognizeTextRequest with orientation handling
│   └── SyncService.swift        # Drive resumable upload + Sheets append, NWPathMonitor
├── Views/
│   ├── CaptureView.swift        # Main bills screen: history list + toolbar add button + sync error banner
│   ├── HistoryView.swift        # List of bills (Files-style), search, swipe to delete
│   ├── ReviewView.swift         # Bill detail: image + form fields + save/update
│   └── SettingsView.swift       # Google account, sheet ID (validated), drive folder ID
└── Resources/
    ├── Info.plist               # Camera/photo permissions, Google OAuth URL scheme
    └── Assets.xcassets/         # App icon (1024x1024 single asset)
```

## Services

### DatabaseService (`@MainActor`)

- SQLite via GRDB. Single `DatabaseQueue`.
- One migration (`v1`) creates the `bills` table.
- `empty()` static method returns an in-memory fallback if disk DB init fails.
- Methods: `insert`, `update`, `fetch(id:)`, `fetchAll`, `fetchPendingSync`, `delete(id:)`, `search(query:)`.
- Search is LIKE-based across vendor, rawText, billNo, gstin.

### OCRService

- Uses `VNRecognizeTextRequest` with `.accurate` recognition level.
- Languages: `en-IN`, `en-US`.
- Passes `CGImagePropertyOrientation` from `UIImage.imageOrientation` to handle rotated photos.
- Returns joined text from all recognized observations.

### SyncService (`@MainActor`)

- Monitors network via `NWPathMonitor` on a background queue.
- `syncPending()` processes all bills with status `saved`.
- Drive upload uses resumable upload (two-step: POST metadata → PUT file). Streams from disk via `URLSession.upload(for:fromFile:)` to handle large files.
- Persists `driveURL` immediately after Drive upload to prevent duplicate uploads on retry.
- Sheets append uses `values/A1:append` with `insertDataOption=INSERT_ROWS`. Raw OCR text truncated to 5000 chars.
- Publishes `lastError` for UI display.

### GoogleAuthService (`@MainActor`)

- Scopes: `drive.file` (create files in Drive), `spreadsheets` (read/write sheets).
- `drive.file` scope means the app can upload to any folder but cannot read existing folders (validation of folder ID is skipped in settings).
- Token refresh before each sync cycle.

### CameraService

- `PhotoLibraryPicker`: PHPickerViewController wrapper for full-size photo library access.
- `CameraPicker`: UIImagePickerController wrapper for camera capture.
- Both return `UIImage` via callback.

## Views

### CaptureView (Bills tab)

- Embeds `HistoryView` as its content.
- Toolbar: `+` menu (top-right) → Take Photo / Choose from Library.
- Sync error banner at bottom via `safeAreaInset`.
- On capture: resizes image (max 2048px), saves to disk, creates draft bill, fires OCR task, navigates to ReviewView.

### HistoryView

- Plain `List` with Files-style rows: 40×40 thumbnail, title, date · amount, status icon.
- Status icons: pencil (draft), arrow.up (saved), checkmark (uploaded).
- Section header shows bill count ("3 bills").
- Search bar always visible below navigation title.
- Swipe to delete (removes file from disk + row from DB).
- Empty states: "No Bills" / search-specific unavailable view.

### ReviewView

- Form with image preview, editable fields, DatePicker for date.
- Fields disabled while OCR in progress (polls DB every 500ms, 15s timeout).
- Fields disabled + Save button hidden when bill is uploaded.
- `saveBill()` re-checks DB status before writing to prevent saving over an uploaded bill.
- Save triggers sync immediately.

### SettingsView

- Google account sign in/out.
- Sheet ID: validated against Sheets API on save (checks 200/404/403).
- Drive folder ID: saved without validation (drive.file scope can't read existing folders).
- Both use half-sheet editor (`presentationDetents([.medium])`).
- Validation status shown as green checkmark / red X on the settings rows.

## Google Sheet Schema

Row appended per bill:

| Column | Value |
|--------|-------|
| A | timestamp (ISO8601) |
| B | drive image URL |
| C | vendor |
| D | date |
| E | amount |
| F | currency |
| G | GST amount |
| H | GSTIN |
| I | bill number |
| J | raw OCR text (truncated 5000 chars) |

## SQLite Schema

```sql
CREATE TABLE bills (
    id          TEXT PRIMARY KEY,
    imagePath   TEXT NOT NULL,
    vendor      TEXT,
    date        TEXT,
    amount      REAL,
    currency    TEXT NOT NULL DEFAULT 'INR',
    gstAmount   REAL,
    gstin       TEXT,
    billNo      TEXT,
    rawText     TEXT,
    status      TEXT NOT NULL DEFAULT 'draft',
    driveURL    TEXT,
    createdAt   DATETIME NOT NULL,
    updatedAt   DATETIME NOT NULL
);
```

## Configuration

- `UserDefaults` keys: `sheet_id`, `folder_id`, `sheet_valid`, `folder_valid`.
- Google OAuth client ID in `Info.plist` (`GIDClientID`).
- URL scheme for OAuth callback in `Info.plist` (`CFBundleURLSchemes`).

## Concurrency Model

- All services are `@MainActor` (`DatabaseService`, `GoogleAuthService`, `SyncService`).
- `OCRService` runs Vision requests via `withCheckedThrowingContinuation` — the handler callback bridges to async/await.
- `SyncService.startNetworkMonitoring()` is `nonisolated` — captures `[weak self]` and dispatches to `@MainActor` via `Task`.
- `Bill` and `Currency` are `Sendable`.

## Known Limitations

- `imagePath` stores absolute paths. Simulator container UUIDs change on reinstall, breaking thumbnails. Not an issue on real devices.
- No offline queue persistence beyond SQLite status — if app is killed mid-OCR, rawText is lost for that bill (user can still fill fields manually).
- Sheets append is not idempotent — if append succeeds but status update fails (crash), retry could create a duplicate row. Drive upload IS idempotent (skips if driveURL already set).
- drive.file scope cannot validate folder existence — folder ID is trusted.

## Image Pipeline

```
UIImage (from camera/library)
  → resize if longest edge > 2048px (UIGraphicsImageRenderer)
  → JPEG compression at 0.80 quality
  → save to Documents/bill_images/{yyyy-MM-dd}_{8-char-uuid}.jpg
  → filename used for Drive upload (lastPathComponent)
```

## Build

```bash
# Requires Xcode 26.3+
xcodegen generate
# Open in Xcode — CLI build has GRDB submodule issues with Xcode 26
open Kharcha.xcodeproj
```

Google Cloud Console setup:
1. Create project, enable Drive API + Sheets API
2. Create iOS OAuth client ID with bundle ID `com.kharcha.app`
3. Client ID goes in Info.plist (`GIDClientID`) and URL scheme (reversed client ID)
4. Add test users in OAuth consent screen → Audience
