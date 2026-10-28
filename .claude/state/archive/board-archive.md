# Board archive

## Phase 1: Example Secret and ConfigMap templates (checkpoint accepted by user, 2026-10-28)
Base: 13e3797d313e67ff601024ab4f9faea684004301 · Phase checks: qc pass (static, tier 1) · security pass (tier 1) · Checkpoint: accepted

| ID | Title | Scope | Status | Commit |
|---|---|---|---|---|
| P1-T1 | cms-api runtime env into api-secrets; rename cms-api templates | core-builder | done | 2fabac3 |
| P1-T4 | Rename and align web, admin and shared templates | core-builder | done | 24c7a49 |
| P1-T2 | api-init-secrets and database-ca-configmap templates | core-builder | done | 2e3c23a |
| P1-T3 | backup-secrets template | core-builder | done | 95e1d9b |
| P1-T5 | configuration.md for the new templates | core-builder | done | ed29542 |

## Rename: frontend to web (checkpoint accepted by user, 2026-10-28)
Base: 13e3797d313e67ff601024ab4f9faea684004301 · Phase checks: qc pass (static, tier 1) · security pass (tier 1) · Checkpoint: accepted · Not pushed; merge waits for staging and prod cutover

| ID | Title | Scope | Status | Commit |
|---|---|---|---|---|
| RW-T1 | Move frontend app wiring to web | core-builder | done | f7a9351 |
| RW-T2 | Names in Flux and Deployments; database-ca mount in cms-api; init reads only api-init-secrets | core-builder | done | 3d7d26b |
| RW-T3 | Template names and object names | core-builder | done | a8182a7 |
| RW-T4 | Docs rename and cutover steps | core-builder | done | c865970 |
