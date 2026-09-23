# Disk-backed clipboard payloads

Image formats and payloads of at least 256 KiB are stored as immutable files in
`Contents/` beside `Storage.sqlite` in Maccy's Application Support directory.
Small text remains inline in SQLite. The model keeps the filename, byte count,
and SHA-256 digest, so loading history, searching, and comparing duplicates do
not load every original image into the application heap.

ImageIO creates a bounded thumbnail directly from its file. Image dimensions are
read from metadata. The full payload is read temporarily for copying or OCR;
visible thumbnails and previews still require memory. Image files retain the
original bytes and all clipboard formats without recompression.

## Existing history

Before the first payload migration, a SQLite online backup (including committed
WAL contents) is saved as `Storage.before-payload-files.sqlite`. Records migrate
in batches of 16 using short-lived contexts. Files are atomically written and
synchronized before their database references replace inline bytes. A failed
batch retains its original database data and retries at the next launch. New
copies fall back to inline storage if writing a file fails.

The first launch can take longer and needs additional disk space for the backup
and payload files. SQLite may retain freed pages for reuse. The storage-size
indicator includes the active database, WAL, and payload files, but not the
migration backup.

After a successful database save, unreferenced files can be deleted. Explicit
history deletion/clearing also discards the migration backup, so that backup does
not retain deleted history. Ordinary replacement/duplicate cleanup is batched
every 30 seconds; interrupted operations are cleaned up at the next launch.

Back up the **entire Maccy directory**, including `Contents/`, rather than just
`Storage.sqlite`. Older application versions cannot read external payloads.
The migration backup is a snapshot of history before migration, not a backup of
subsequent copies. Test fixtures and test payload directories contain synthetic
data and are separate from the running application's storage.

## Validation

Tests cover migration from a database produced by commit `bc74559`, reopening a
persistent store, byte-for-byte clipboard copying to a private pasteboard,
missing-file handling, duplicate transfer/deletion, and thumbnail dimensions.
The legacy fixture contains only a generated red image and the text `legacy text`.

```sh
xcodebuild test -project Maccy.xcodeproj -scheme Maccy \
  -destination 'platform=macOS' -only-testing:MaccyTests \
  -skip-testing:MaccyTests/ClipboardTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

`ClipboardTests` uses the system clipboard and frontmost application; new disk
copy tests use a private named pasteboard instead.
