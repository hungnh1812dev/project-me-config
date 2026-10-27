# Board - project-me config (deploy repo)
Source: .claude/state/tasks/phase-1.md, .claude/state/tasks/rename-web.md · Spec: none
Decisions: see handoff.md "User decisions" and "Naming decisions (final, from user)"
Open risks: Phase 1 and the rename must merge together (develop -> staging -> main); cms-api database-ca mount added in RW-T2

## Done
- Phase 1 (templates): checkpoint accepted, archived.
- Rename frontend to web (RW-T1 to RW-T4): checkpoint accepted, archived. Not pushed; merge waits for the user's staging and prod cutover.

## Notes
- Follow-up: APP_API_URL removal once the frontend image reads API_INTERNAL_URL.
