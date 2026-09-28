# Project SaaS local test workspace

* Read project\_handoff\_business\_decisions.md and MIGRATION\_NOTES.md first. Preserve the agreed Lead workflow, permissions, tenancy, Quote history and acceptance behavior.
* Read README.md for the actual verification state. Supabase Local and the 66 pgTAP assertions have NOT run in the originating environment because Docker is unavailable there.
* Source of SQL edits: source\_migrations/\*.sql. Run npm run migrations:sync after editing; verify copies using npm run check.
* Use the pinned CLI via npm scripts. Only use the local test database; no cloud linking, remote reset, deployment or db push is authorized.
* The user authorizes setup and testing against the disposable local database, including reset of this test project. Do not reset another project or overwrite unrelated data.
* \- Use verification proportional to the scope of the change. Do not run the full test suite by default for every change.
* &#x20; - UI/CSS/layout only: run necessary lint/typecheck and verify the affected UI.
* &#x20; - Frontend component/state/interaction: run lint, typecheck, relevant tests, and verify the affected UI.
* &#x20; - API/business logic: also run relevant backend/API tests.
* &#x20; - Database/schema/migration/RLS/policy: run full database verification: npm run check, npm run local:start when needed, npm run db:reset, npm run db:lint, and npm run db:test.
* &#x20; - Run full verification for smaller changes only when there is a specific reason to suspect wider regression.
* \- Prefer the smallest sufficient verification that gives confidence in the change. Report what was tested and what relevant checks were intentionally skipped as out of scope.
* Fix technical errors and rerun affected verification. Do not silently modify business decisions to make tests pass.
* Tests run fixtures as postgres but switch to authenticated with test JWT subject for user operations. Preserve these switches: testing everything as a privileged role would bypass RLS.
* Existing tests are initial workflow coverage, not exhaustive concurrency/API testing. Add meaningful checks for concrete uncovered risks.
* Report actual commands/results, blockers and untested areas. Always suggest the user's next step when completing work.
