# CDC Online Test

A free online MCQ test platform for campus batches: email login, Excel question upload, timer, autosave, tab-switch detection, and an Excel results export. It runs on free hosting (GitHub Pages) with a free Supabase database.

## Files
- `index.html` is the whole app. Students open `…/index.html?t=CODE`, and the admin opens `…/#admin`.
- `setup.sql` contains the database tables and functions. Run it once in Supabase › SQL Editor.
- `src/` holds the source files, and `build.py` rebuilds `index.html` from them.

## One-time setup
1. In Supabase, create a project, then go to SQL Editor › New query, paste `setup.sql` and click Run.
2. In Supabase › Project Settings › API, copy the Project URL and the anon/publishable key into the SETTINGS block of `index.html`.
3. In GitHub, go to Settings › Pages, set Source to "Deploy from a branch", and pick branch `main` with folder `/ (root)`.
4. Open `https://<user>.github.io/<repo>/#admin`, create the admin password, and create a test.

## Question file format
Each Excel file becomes one section. It needs these columns:
- **Question**
- **Option A**, **Option B**, and optionally **Option C** and **Option D**
- The answer, given in one of two ways:
  - a **Correct Option** column containing A/B/C/D, or
  - a separate **Answer Key** sheet with **Question No.** and **Correct Option** columns.

An optional **Topic** column enables topic-wise results.

## How it protects the test
- The answer key never reaches the student's browser. Grading happens in the database.
- The database tables are locked, so the browser can only call the test functions.
- Each email gets one attempt. A started attempt can only be resumed on the same device unless the admin unlocks it.
- Question and option order is shuffled per student.
- Leaving the window, switching tabs or exiting fullscreen is counted. The test auto-submits after the configured limit.
