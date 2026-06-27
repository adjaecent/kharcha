# App Review Notes

These go in App Store Connect → App Review Information → Notes, and the demo
account fields.

## Sign-in / demo account

Kharcha requires signing in with Google to sync bills to the reviewer's own
Google Drive. Please use the following test account, which is ready to use:

- Google email: __________________________
- Password: __________________________

_(Provide a real Google test account. If the account has 2FA, either disable it
for review or supply a way for the reviewer to pass it. App Review cannot
complete sign-in without a working account.)_

## How to test

1. Launch the app and tap **Sign in with Google**, using the account above.
2. Grant the requested permission. Kharcha asks only for access to files it
   creates in Drive (the `drive.file` permission), so the consent screen lists
   Google Drive access for app-created files.
3. On the main screen, tap **+** (top right) and choose **Take Photo**,
   **Choose Photo**, or **Choose File** (for a PDF invoice). A sample receipt
   image works fine.
4. The app reads the bill on-device and fills in vendor, amount, date, and tax.
   Review the form and tap **Save**.
5. The bill syncs to a folder named "Kharcha Bills" in the test account's Google
   Drive, and a row is added to the "List" spreadsheet there.

## Notes for the reviewer

- **All recognition and extraction is on-device** (Apple Vision + Apple
  Intelligence). No bill data is sent to any server owned by us.
- **The only network access** is to Google Drive and Google Sheets, using the
  signed-in account, to store the user's own bills.
- **Apple Intelligence:** detail extraction uses Foundation Models when
  available on the device. On devices without Apple Intelligence, the app still
  works: OCR runs, and the user fills in details manually. The form unlocks for
  manual entry automatically.
- **Camera and photo permissions** are used only to capture or select a bill
  image, as described in the permission prompts.

## Contact
mail@kitallis.in
