# Task Tracking Setup Prompt

Copy and paste this prompt into another project to create a lightweight backlog, follow-ups, and archive workflow.

````markdown
Set up a lightweight project task-tracking system similar to this:

- `docs/BACKLOG.md` for committed, actionable work
- `docs/FOLLOWUPS.md` for lower-confidence ideas or future improvements
- `docs/BACKLOG_ARCHIVE.md` for completed backlog items

First, inspect the project enough to understand its purpose, tech stack, existing docs, test/build commands, and conventions. Then create or update the docs using project-specific wording, not generic placeholder text.

Requirements:

1. Create `docs/BACKLOG.md`
   - Title: `# <Project Name> Backlog`
   - Include a short goal statement describing what kinds of improvements belong here.
   - Explain that completed items should move to `BACKLOG_ARCHIVE.md` with completion date, summary, and verification.
   - Add a `## Priority Tasks` section.
   - Use priorities:
     - `P0`: correctness, data loss, security/privacy, crashes, broken core workflows
     - `P1`: important usability, reliability, maintainability, performance, missing tests
     - `P2`: polish, cleanup, documentation, nice-to-have improvements
   - For each backlog item, use this format:

```markdown
### P1 - Task title

- Area: Affected file, module, feature, or behavior.
- Evidence: What shows this is a real issue or useful improvement.
- Acceptance criteria:
  - Concrete condition that must be true when complete.
  - Include tests, docs, or manual checks when appropriate.
- Verification: Build, test, lint, or manual workflow that should prove the task is done.
```

   - If there are no committed tasks yet, say:
     `No committed tasks are currently pending.`

2. Create `docs/BACKLOG_ARCHIVE.md`
   - Title: `# <Project Name> Backlog Archive`
   - Explain that completed backlog tasks move here from `BACKLOG.md`.
   - Keep newest completions at the top.
   - Include this archive format:

```markdown
### YYYY-MM-DD - Task title

- Source: P0/P1/P2 from `BACKLOG.md`
- Summary: What changed and why.
- Verification: Build, test, lint, or manual check used.
```

   - Add a `## Completed Tasks` section.
   - If there are no completed tasks yet, say:
     `No completed backlog tasks yet.`

3. Create `docs/FOLLOWUPS.md`
   - Title: `# <Project Name> Follow-Ups`
   - Explain that follow-ups are ideas worth revisiting later, but not committed backlog work yet.
   - Say to promote an item to `BACKLOG.md` only when it has a clear problem statement, priority, evidence, and acceptance criteria.
   - Add a `## Future Improvements` section.
   - Use this format:

```markdown
- [ ] Idea title.
  - Why later: Explain what makes this worth deferring or what uncertainty remains.
```

4. Add project-specific seed items only if you find clear evidence while inspecting the repo.
   - Put concrete, actionable work in `BACKLOG.md`.
   - Put speculative ideas in `FOLLOWUPS.md`.
   - Do not invent vague tasks just to fill the files.

5. If the project has an agent/developer guide such as `CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`, or similar, update it with a short "Task Tracking" section:

```markdown
## Task Tracking

Use the docs folder to track product and engineering work:

- `docs/BACKLOG.md` - Committed todo tasks with priority, evidence, acceptance criteria, and verification.
- `docs/FOLLOWUPS.md` - Ideas or possible future improvements that are not ready for the backlog yet.
- `docs/BACKLOG_ARCHIVE.md` - Completed backlog tasks, including date, summary, and verification.

Workflow:
1. Add actionable issues found during implementation or review to `docs/BACKLOG.md`.
2. Add lower-confidence ideas or later enhancements to `docs/FOLLOWUPS.md`.
3. When a backlog item is completed, move it to `docs/BACKLOG_ARCHIVE.md`.
4. Keep backlog items concrete: affected area, why it matters, what done means, and how to verify it.
```

6. Keep the setup minimal and maintainable.
   - Do not add project management dependencies.
   - Do not create issue templates unless the repo already uses them.
   - Do not rewrite unrelated docs.
   - Preserve existing style and formatting conventions.

After making the changes, summarize:
- Which files were created or updated.
- Any seed backlog/follow-up items added.
- Whether any existing project guide was updated.
````
