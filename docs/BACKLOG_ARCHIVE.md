# MacClipboard Backlog Archive

Completed backlog tasks move here from `BACKLOG.md`. Keep newest completions at the top.

## Archive Format

Use this format for each completed item:

```markdown
### YYYY-MM-DD - Task title

- Source: P0/P1/P2 from `BACKLOG.md`
- Summary: What changed and why.
- Verification: Build, test, or manual check used.
```

## Completed Tasks

### 2026-07-04 - Add automated coverage for sensitive-content detection

- Source: P0 from `BACKLOG.md`
- Summary: Added XCTest coverage for API keys, password-like strings, common false positives, large-text pattern limits, and preference-policy interactions.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Add automated coverage for clipboard history metadata preservation

- Source: P0 from `BACKLOG.md`
- Summary: Extracted duplicate-history insertion into a pure helper and added tests for duplicate text, image, and file captures preserving metadata and moving to the top only when appropriate.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Move persistence work onto a dedicated Core Data background context

- Source: P0 from `BACKLOG.md`
- Summary: Moved persistence operations off the main view context and onto a dedicated private-queue Core Data context; startup history loading now fetches away from the main thread.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Replace Core Data fatalError with graceful recovery

- Source: P0 from `BACKLOG.md`
- Summary: Replaced persistent-store load termination with temporary in-memory storage, diagnostics, and a user-visible reset-and-quit recovery path.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`
