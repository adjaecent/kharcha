# Privacy Policy for Kharcha

_Last updated: 27 June 2026_

Kharcha ("the app", "we", "us") helps you capture bills and receipts and keep
them organised in your own Google account. This policy explains what the app
does with your data. In short: your bills and their details live on your device
and in your own Google Drive. We do not run servers, and we never receive,
store, or sell your data.

## Who provides the app

Kharcha is built by Akshay Gupta. Contact: mail@kitallis.in.

## What data the app handles

- **Bill images and PDFs** you capture or import. These are stored on your
  device and uploaded to a folder named "Kharcha Bills" in your own Google
  Drive.
- **Details read from your bills**, such as vendor, date, amount, tax amount,
  tax ID, and bill number. These are stored on your device and written to a
  spreadsheet named "List" inside that same Google Drive folder.
- **Your Google account sign-in.** When you sign in with Google, the app
  receives an access token so it can create and update its own files in your
  Drive. The app uses the `drive.file` permission, which limits access to only
  the files the app itself creates. The app cannot see any other files in your
  Drive.

## How the data is processed

- **Text recognition (OCR)** runs entirely on your device using Apple's Vision
  framework. Bill images are not sent anywhere for text recognition.
- **Detail extraction** runs entirely on your device using Apple Intelligence
  (Foundation Models), when available. Your bill text is not sent to us or to
  any third party for extraction.
- **Sync** sends your bill images and details only to Google Drive and Google
  Sheets, within your own Google account, using Google's official APIs.

## What we do not do

- We do not operate any backend server that receives your data.
- We do not use analytics, advertising, or tracking SDKs.
- We do not collect your data for our own use, and we do not sell or share it
  with third parties.

## Third-party services

The app uses Google Sign-In and the Google Drive and Google Sheets APIs to store
your data in your own Google account. Your use of Google services is governed by
Google's Privacy Policy: https://policies.google.com/privacy

## Data retention and deletion

Your data is retained for as long as you keep it. You can delete it at any time:

- Delete individual bills in the app.
- Delete the "Kharcha Bills" folder from your Google Drive to remove the synced
  copies.
- Sign out of Google in the app to revoke the app's access token, and remove
  Kharcha's access from your Google Account settings
  (https://myaccount.google.com/permissions).
- Delete the app to remove the on-device copy.

## Children

Kharcha is not directed at children under 13 and does not knowingly collect data
from them.

## Changes to this policy

If this policy changes, we will update the date above and post the revised
version at the same URL.

## Contact

Questions about this policy: mail@kitallis.in
