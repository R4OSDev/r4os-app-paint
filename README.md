# PAINT.R4X

`PAINT.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.11`
- Image target: `/R4OS/SOFTWARE/DESKTOP/PAINT.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


Document saving (0.78.69)
--------------------------
Notepad 0.1.11 and Paint 0.1.7 share the SDK document_save.Saver policy.
Save and Save As first create a private 8.3 sibling (DSxxxxxx.TMP), write
bounded chunks and confirm the final stream flush. Only then does the
existing Files.replaceAtomic facade publish the target. An old document is
never passed to fileWrite. Path, Dirty and recent-file history change only
after confirmed replacement. A truncated Notepad load also requires the
target to remain absent at the atomic publication boundary.

A failure before replacement aborts only the exact owned stream. An
unconfirmed replacement retains the stage and backup for recovery, while
the app keeps its edited document. A confirmed save with failed backup
cleanup stays successful and reports the retained backup. The temporary
names remain in the target directory; there is no direct-write fallback.
Existing FAT long names can be replaced, but creation of a new FAT long
name is not supported by the current atomic storage primitive. Such a
request fails without falling back to an unsafe overwrite.

One host case injects a single short stage write and checks unchanged
Notepad text, selection, path, Dirty and pending history, no replacement,
and cleanup of the owned stage. One short SMP4 console probe calls the real
Notepad methods on private FAT files and the real Paint methods on private
NTFS files: Save and Save As over existing targets, exact saved bytes,
metadata and sibling cleanup. It also confirms fresh Save As of a Notepad
prefix through the create-only atomic path. Both product modules build.


Damage and event batching (0.81.20)
---------------------------------
Hosted Paint drains at most 32 ordered GUI messages before publishing one
frame. Changed image pixels form one bounded source rectangle; status damage
is separate. Repeated unchanged samples upload no image. A changed point in
the default 64x48 image sends 4 raster bytes instead of 12288 (UI commands
are additional). Bresenham segments and pencil/eraser order are preserved.
The existing transactional buffered Canvas handles command batching and
cancels on append/commit failure. Retry, missing damage ABI, resize/font,
menus/dialogs/tools, unsafe work-area boundaries and delta-chain compaction
produce complete frames. No new SDK/ABI or generic FPS gate was added.
Mouse-down dispatch enters the menu only for an open menu or its bar; a
closed menu no longer consumes toolbar and drawing-area clicks as backdrop.
A focused host case uses the actual App and real SDK with captured commands:
full/delta raster-and-rectangle replay, ordered crossing strokes, eraser,
no-op, input dispatch, append OOM, chain reset and unavailable damage ABI.
Three existing buffered-Canvas conformance cases also pass. Text rendering
is covered by the existing facade checks, not the temporary pixel replayer.
No QEMU or physical hardware was needed for this application-only change.

Unicode dialog contract (0.85.43)
--------------------------------
Save-as fields accept complete Unicode scalar events and keep separate byte
cursor/selection positions. Invalid or overlong preloads and failed insertions
preserve the previous input; a rejected filename cannot be saved until edited
or replaced by a valid selection. Initial path arguments and constructed paths
are checked in full, before copying or filesystem access. Directory labels may
show a whole-scalar prefix plus ...; the stored full path alone identifies a row.
Glyph coverage is independent of text input. No normalization, grapheme, Bidi
or shaping promise follows from these scalar operations.
Build.sh test (Build.bat test on Windows) exercises the actual app dialog owner.
Tests/DialogText is an explicit IMAGE_SCOPE=none console fixture of the same app
source. /DIALOGTEST additionally verifies real private file saves, full Unicode
row identity, failure-state preservation and cleanup; Notepad checks actual
search values too. It does not claim a manual visual GUI acceptance.
Appending the default .BMP suffix also requires its complete byte capacity;
a partial extension is never used as a target.
