# Kharcha — Architecture

A native iOS app for capturing bill photos, extracting details via on-device AI, and syncing to Google Sheets + Drive.

## Target

- iOS 26+, Swift 6.2, Xcode 26.3
- SPM dependencies: GRDB (SQLite), GoogleSignIn-iOS
- System frameworks: Vision (OCR), FoundationModels (field extraction), Network (reachability)
- No other third-party dependencies.

## Core Flow

```
take photo / pick from library / pick file (image or PDF)
  → PDFs: up to 4 pages rendered and stitched vertically into one image
  → resize (longest edge 2048px; very tall images cap width 2048 / height 8192
    so stitched PDFs and long receipts keep text resolution), JPEG 0.80
  → save image to disk (Documents/bill_images/, stored as relative path)
  → insert SQLite row as 'draft' (image path + created_at)
  → BillProcessor pipeline (tracks in-flight bills; resumable):
      Phase 1: Vision OCR → update rawText in DB
      Phase 2: Foundation Models extraction (if Apple Intelligence available)
        → extract vendor, date, amount, currency, GST, GSTIN, bill no, category
        → update fields in DB, set extractionDone = true
  → navigate to review screen

review screen
  → show image + editable fields
  → two-phase processing indicator:
      "Reading bill..." (OCR in progress)
      "Extracting details..." (Foundation Models in progress)
  → form disabled until extractionDone = true (or 30s timeout)
  → form disabled if bill is already uploaded
  → user confirms/edits fields, taps Save → status becomes 'saved'

sync (background)
  → triggered on: save, app foreground (scenePhase .active), network
    reachability change, credentials validated in Settings
  → ensure the app-created Drive artifacts exist (cached ID → find by
    name → create; user can move/rename them freely):
      "Kharcha Bills" folder, and "List" spreadsheet inside it
      (created with a header row)
  → for each bill with status 'saved' (per-bill error handling — one bad
    bill doesn't block the rest; credential errors stop the loop early):
      1. upload image to the Kharcha Bills folder (resumable upload) — skipped if driveURL already set
      2. append row to the List spreadsheet (Sheets API v4, RAW input mode) —
         skipped if sheetAppended already set (prevents duplicate rows on retry)
      3. mark status 'uploaded'
  → runs inside a UIApplication background task so in-flight uploads can
    finish if the user backgrounds the app
  → errors surface as a red ⚠ toolbar button on the bills list;
    tapping it shows an alert with a human-readable message + Retry
  → if the folder or spreadsheet was permanently deleted (404), its cached
    ID is cleared and it's recreated on the next sync — self-healing, no
    user action needed
```

## Status Machine

```
draft → saved → uploaded
```

- `draft`: image captured, OCR/extraction may be in progress, user hasn't confirmed fields
- `saved`: user confirmed, pending sync
- `uploaded`: synced to Drive + Sheets. Form becomes read-only.

Re-editing an uploaded bill is not allowed. `saveBill()` re-checks DB status before writing.

## Project Structure

```
Kharcha/
├── App.swift                    # Entry point, service wiring, tab view, first-run routing
├── Models/
│   ├── Bill.swift               # GRDB Record — all bill fields + extractionDone flag
│   └── Currency.swift           # Enum: INR, USD, EUR, GBP, ZAR, KRW, JPY, CAD, ISK
├── Services/
│   ├── BillProcessor.swift      # OCR → extraction pipeline, in-flight tracking, resume for stranded drafts
│   ├── CameraService.swift      # PHPicker (library) + UIImagePicker (camera) + document picker (images/PDFs)
│   ├── DatabaseService.swift    # GRDB: migrations (v1-v4), CRUD, search, observation, pending sync query
│   ├── ExtractionService.swift  # Foundation Models: @Generable struct for typed field extraction
│   ├── GoogleAuthService.swift  # Google Sign-In: sign in/out, token refresh, scopes
│   ├── OCRService.swift         # Apple Vision: VNRecognizeTextRequest with orientation handling
│   └── SyncService.swift        # Drive resumable upload + Sheets append, NWPathMonitor
├── Views/
│   ├── CaptureView.swift        # Main bills screen: history list + toolbar add button + sync error banner
│   ├── HistoryView.swift        # List of bills (Files-style), search, swipe to delete
│   ├── ReviewView.swift         # Bill detail: image + form fields + category picker + save/update
│   └── SettingsView.swift       # Google account + spreadsheet config in single section
└── Resources/
    ├── Info.plist               # Camera/photo permissions, Google OAuth URL scheme
    └── Assets.xcassets/         # App icon (1024x1024 single asset)
```

## Services

### DatabaseService (`@MainActor`)

- SQLite via GRDB. Single `DatabaseQueue`.
- Four migrations: `v1` (bills table), `v2` (extractionDone column), `v3` (category column), `v4` (sheetAppended column + backfill, absolute→relative imagePath fixup).
- `empty()` static method returns an in-memory fallback if disk DB init fails.
- Methods: `insert`, `update`, `fetch(id:)`, `fetchPendingSync`, `fetchUnprocessed`, `delete(id:)`, `observeBills(matching:)`, `observeBill(id:)`.
- Search is LIKE-based across vendor, rawText, billNo, gstin.
- `observeBills(matching:)` / `observeBill(id:)` return GRDB `AsyncValueObservation`s that re-emit whenever the rows change — they drive the live list and the review screen's processing indicator.

### BillProcessor (`@MainActor`)

- Owns the two-phase pipeline (OCR → extraction) that used to live inline in CaptureView.
- Tracks in-flight bill IDs so the same bill is never processed twice concurrently.
- `resumeIfNeeded(bill:db:)` restarts the pipeline from the image on disk for drafts whose pipeline never finished (app killed mid-OCR/extraction). Called when ReviewView opens an unfinished draft.

### OCRService

- Uses `VNRecognizeTextRequest` with `.accurate` recognition level.
- Languages: `en-IN`, `en-US`.
- Passes `CGImagePropertyOrientation` from `UIImage.imageOrientation` to handle rotated photos.
- Returns joined text from all recognized observations.

### ExtractionService

- Uses Apple Foundation Models framework (`FoundationModels`).
- `@Generable` struct `ExtractedBillFields` with `@Guide` annotations for each field.
- Extracts: vendor, date, amount, currency, gstAmount, gstin, billNo, category.
- Category uses `.anyOf` constraint with predefined expense categories.
- `isAvailable` checks `SystemLanguageModel.default.availability` — only runs on devices with Apple Intelligence (A17 Pro+).
- Falls back gracefully: if unavailable, fields are left empty for manual entry.
- Prompt tuned to distinguish GSTIN from FSSAI, use Grand Total not subtotals, convert 2-digit years, and handle non-Indian tax terminology (VAT/sales tax + VAT registration numbers) for foreign bills. OCR input truncated to 4000 chars (sized for multi-page stitched PDFs).
- Prompts deliberately use GST/GSTIN/VAT terms (not the UI's generic "Tax Amount"/"Tax ID") — extraction needs the literal labels printed on bills.

### SyncService (`@MainActor`)

- Monitors network via `NWPathMonitor` on a background queue.
- Owns the Drive destination: `ensureAppFolder()` / `ensureAppSheet()` return the app-created "Kharcha Bills" folder and the "List" spreadsheet inside it, creating them on first sync (the spreadsheet gets a header row). Both are tagged with a `kharcha_role` appProperty (folder/sheet) at creation. Lookup order for each: cached ID (`app_folder_id` / `app_sheet_id`, verified via files.get, which works because the app created them; the check also catches trashed files, which uploads alone would not) → search by `kharcha_role` tag (reinstall recovery; rename- and move-proof; drive.file scope only lists app-created files) → create. The user can move or rename both freely. Setup network calls are skipped entirely when no bills are pending.
- `syncPending()` processes all bills with status `saved`, with per-bill error handling: one failing bill doesn't block the rest, but a credential error (401/403/404) stops the loop since every bill would fail the same way.
- Wraps the sync cycle in `UIApplication.beginBackgroundTask` so in-flight uploads get extra runtime if the app is backgrounded.
- Drive upload uses resumable upload (two-step: POST metadata → PUT file). Streams from disk via `URLSession.upload(for:fromFile:)` to handle large files.
- Persists `driveURL` immediately after Drive upload to prevent duplicate uploads on retry; persists `sheetAppended` immediately after the Sheets append to prevent duplicate rows on retry.
- Sheets append uses `values/A1:append` with `valueInputOption=RAW` and `insertDataOption=INSERT_ROWS`. RAW prevents date auto-parsing as serial numbers.
- Raw OCR text truncated to 5000 chars.
- Publishes `lastError` for UI display — mapped to short text rather than
  raw HTTP bodies. A 404 on upload or append clears the relevant cached ID
  so the folder/spreadsheet is recreated on the next sync.

### GoogleAuthService (`@MainActor`)

- Scopes: `drive.file` (create + manage files the app created), `spreadsheets` (read/write sheets).
- The app only ever touches files it created — the "Kharcha Bills" folder and the "List" spreadsheet — so `drive.file` gives it full read/write/search over everything it needs. No user-facing Drive configuration at all.
- Token refresh before each sync cycle.

### CameraService

- `PhotoLibraryPicker`: PHPickerViewController wrapper for full-size photo library access.
- `CameraPicker`: UIImagePickerController wrapper for camera capture.
- `DocumentPicker`: UIDocumentPickerViewController for images and PDFs. PDFs render up to 4 pages stitched vertically into one tall image so multi-page invoices keep all their text for OCR.
- All return `UIImage` via callback.

## Views

### CaptureView (Bills tab)

- Embeds `HistoryView` as its content.
- Toolbar: `+` menu (top-right, 44×44 tap target) → Take Photo / Choose Photo / Choose File.
- On sync error: red ⚠ button appears top-leading; tapping shows an alert with the error message and a Retry action.
- On capture: resizes image, saves to Documents/bill_images/ (relative path in DB), creates draft bill, hands off to `BillProcessor`, navigates to ReviewView.
- On capture: resizes image (max 2048px), saves to disk, creates draft bill, fires two-phase background task (OCR → extraction), navigates to ReviewView.

### HistoryView

- Plain `List` with Files-style rows: 44×56 thumbnail, title, date · amount, category, status icon.
- Status icons: pencil (draft), arrow.up (saved), checkmark (uploaded), icloud.slash (saved but not syncable).
- Live-updating: a GRDB observation (`.task(id: searchText)`) re-emits whenever rows change, so OCR results and sync status appear without manual refresh.
- Section header shows bill count ("3 bills"), top separator hidden.
- Search bar always visible below navigation title.
- Swipe to delete (removes DB row first, then file from disk; the observation updates the list).
- Empty states: "No Bills" / search-specific unavailable view.

### ReviewView

- Form with image preview, editable fields, DatePicker for date, category Picker.
- Two-phase processing: "Reading bill..." → "Extracting details..." → form unlocked. The phase derives from the observed bill row (GRDB `observeBill`); a 30s timeout unlocks the form for manual entry if extraction never finishes (late results won't clobber manual edits).
- Stranded drafts (app killed mid-pipeline) are resumed by a `BillProcessor.resumeAllPending` sweep at app launch, not per-screen.
- Amounts parsed locale-aware (`Double(_:)` first, then `NumberFormatter`) so "," decimal separators work.
- Fields disabled + Save button hidden when bill is uploaded.
- `saveBill()` re-checks DB status before writing to prevent saving over an uploaded bill.
- Save triggers sync immediately.

### SettingsView

- "Google Account" section: sign in / account email + sign out. No IDs to configure — the app creates and manages its own Drive folder and spreadsheet.
- "Your Data" card (signed in): iOS Settings-style note — icon tile, title, explanatory text — describing where bills go, with "Open List Spreadsheet" / "Open Kharcha Bills Folder" link rows once the artifacts exist (text switches to "created on first sync" before then).
- Sign-in triggers a sync immediately.

## Expense Categories

Auto-categorized by Foundation Models, user can override in review screen:

- Purchases (Goods)
- Direct Expenses
- Rent & Utilities
- Software & SaaS
- Professional Fees
- Marketing & Ads
- Travel
- Meals
- Bank Charges
- Capital Assets
- Taxes
- Miscellaneous

## Google Sheet Schema

The "List" spreadsheet is created with a header row matching the columns
below. Row appended per bill (RAW input mode):

| Column | Header | Value |
|--------|--------|-------|
| A | Upload Date | timestamp (ISO8601) |
| B | File | drive image URL |
| C | Vendor | vendor |
| D | Bill Date | date |
| E | Bill Amount | amount |
| F | Currency | currency |
| G | Tax Amount | tax amount (CGST+SGST or IGST) |
| H | Tax Number | GSTIN |
| I | Bill number | bill number |
| J | Category | category |
| K | Raw OCR data | raw OCR text (truncated 5000 chars) |

UI labels say "Tax Amount" / "Tax ID"; the extraction prompts deliberately
keep GST/GSTIN terminology because prompts need the specific terms found on
Indian bills.

## SQLite Schema

```sql
-- v1
CREATE TABLE bills (
    id              TEXT PRIMARY KEY,
    imagePath       TEXT NOT NULL,
    vendor          TEXT,
    date            TEXT,
    amount          REAL,
    currency        TEXT NOT NULL DEFAULT 'INR',
    gstAmount       REAL,
    gstin           TEXT,
    billNo          TEXT,
    rawText         TEXT,
    status          TEXT NOT NULL DEFAULT 'draft',
    driveURL        TEXT,
    createdAt       DATETIME NOT NULL,
    updatedAt       DATETIME NOT NULL
);

-- v2
ALTER TABLE bills ADD COLUMN extractionDone BOOLEAN NOT NULL DEFAULT 0;

-- v3
ALTER TABLE bills ADD COLUMN category TEXT;

-- v4
ALTER TABLE bills ADD COLUMN sheetAppended BOOLEAN NOT NULL DEFAULT 0;
UPDATE bills SET sheetAppended = 1 WHERE status = 'uploaded';
-- plus a fixup converting absolute imagePath values to Documents-relative
```

`imagePath` is stored relative to the Documents directory (`bill_images/…`);
`Bill.absoluteImagePath` resolves it at read time (absolute legacy paths pass
through unchanged).

## Configuration

- `UserDefaults` keys: `app_folder_id`, `app_sheet_id` (cached IDs of the app-created Drive folder and spreadsheet; not user-configurable).
- Google OAuth client ID in `Info.plist` (`GIDClientID`).
- URL scheme for OAuth callback in `Info.plist` (`CFBundleURLSchemes`).

## Concurrency Model

- All services are `@MainActor` (`DatabaseService`, `GoogleAuthService`, `SyncService`).
- `OCRService` runs Vision requests via `withCheckedThrowingContinuation` — the handler callback bridges to async/await.
- `ExtractionService` uses async `LanguageModelSession.respond(to:generating:)`.
- `SyncService.startNetworkMonitoring()` is `nonisolated` — captures `[weak self]` and dispatches to `@MainActor` via `Task`.
- `Bill` and `Currency` are `Sendable`.

## Known Limitations

- Foundation Models requires Apple Intelligence (A17 Pro+). On older devices (e.g., iPhone 13 mini), fields are empty and user fills them manually.
- Background runtime for sync is the ~30s `beginBackgroundTask` grace period, not a background `URLSession` — very large uploads on slow connections can still be suspended mid-flight (Drive's resumable protocol means the retry starts over).
- A tiny crash window remains between the Sheets append succeeding and `sheetAppended` being persisted — far smaller than before, but not zero.
- PDFs beyond 4 pages are truncated to the first 4.
- Installs upgraded from the user-configured era keep their old images and rows in the previously chosen folder/sheet; new data goes to the app-created ones.

## Image Pipeline

```
UIImage (from camera/library/file picker)
  → resize (UIGraphicsImageRenderer):
      normal aspect: longest edge capped at 2048px
      tall (h/w > 2.5, e.g. stitched PDFs, long receipts):
        width capped at 2048px, height at 8192px
  → JPEG compression at 0.80 quality
  → save to Documents/bill_images/{yyyy-MM-dd}_{8-char-uuid}.jpg
  → DB stores the relative path (bill_images/…)
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
2. Create iOS OAuth client ID with bundle ID `kharcha.app`
3. Client ID goes in Info.plist (`GIDClientID`) and URL scheme (reversed client ID)
4. Add test users in OAuth consent screen → Audience

No per-user setup beyond signing in — the app creates its own Drive folder
("Kharcha Bills") and spreadsheet ("List") on first sync.
