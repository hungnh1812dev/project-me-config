# Project Profile
Tasks: planner task files under .claude/state/tasks/ (phase-1.md for the Secret/ConfigMap templates, rename-web.md for the frontend to web rename); tasks by ID
Phases: Phase 1 in board.md (templates); rename in board.md as a flat list
Spec: none yet; deployment/*.md are reference docs
Scopes:
- core-builder: templates/, deployment/*.md, docs/, README.md, apps/, cluster-base/, cluster/ (not cluster/me/*/project-me-* bootstrap folders)
- ui-builder: n/a
- qc: n/a
High-risk paths: templates/*secret*.yaml, deployment/k3s-secrets-sops.md, apps/, cluster-base/, cluster/me/*/ (overlays and Kustomizations)
Stack: deploy repo, Kubernetes/Flux YAML and markdown
Commands:
- install / build / type-check / unit test / integration test / format / dependency audit / run app: n/a
- dev stack (tier 2): n/a
- full stack (tier 3): n/a
- e2e single spec: n/a
Tier 3 also when: none
E2E tests: none
Docs to keep current: deployment/*.md, docs/, README.md
Security rules: CD must not read any .env* file; all runtime config comes from ConfigMap or Secret
