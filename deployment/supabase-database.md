# Supabase database: roles, TLS, secrets, backups

How the production database runs on a Supabase free project. It is the operator's guide for ADR 0012 section 9 (roles, TLS) and ADR 0013 (backups). The deploy order is `docs/deployment/devops-runbook.md`; the owner's own dashboard steps are in `docs/deployment/supabase-owner-setup.md` (Vietnamese). This file links to those and does not repeat them.

Status: nothing here has run against a Supabase project from this repo yet. The roles script and the TLS keys are built and tested on throwaway containers (`scripts/db/database-roles.sql`, the smoke stack). The proof on the real project is steps S3 to S7 below, recorded under LG-0 item 6 and LG-db-7.

Every value in `<angle brackets>` is yours to fill in on your own machine or in an encrypted Secret. No password, key or token is written in any file of this repo.

## 1. Facts to rely on

- **Postgres 17.** The project, the local test containers and the backup image all use major version 17. Use `psql` 17 and `pg_dump` 17 or newer: an older `pg_dump` refuses to dump a newer server.
- **Session pooler on port 5432, never 6543.** The session pooler (Supavisor) works over IPv4 on the free plan and keeps session state. The transaction pooler on 6543 breaks prepared statements, session state and advisory locks, and Prisma migrate and the content runner depend on them. The direct connection is IPv6 only on the free plan and is not used.
- **User names carry the project suffix.** Through the pooler the connection user is `<role>.<project-ref>` (for example `abyss_api.<project-ref>`). That string goes into `DB_USERNAME`. Inside the database, in the roles script variables and in `current_user`, the role is the plain name (`abyss_api`).
- **`postgres` is not a superuser.** It is the most privileged role a project gives. So there is no superuser step, the database owner cannot change, and the script never re-owns anything.
- **Database `postgres`, TLS `verify-full`.** `DB_NAME=postgres`. "Enforce SSL" is on in the dashboard and cms-api checks the server certificate against the CA you download there.
- **Data API off.** With it on, the project's anon key could read and write the app tables directly, past every cms-api rule and every masking rule.

## 2. Roles

| Role in the database | Pooler user name (`DB_USERNAME`) | Used by                                                                   | Created by                                                                        |
| -------------------- | -------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `postgres`           | `postgres.<project-ref>`         | init container (`deploy:migrate`), the roles script, the disaster restore | Supabase                                                                          |
| `abyss_api`          | `abyss_api.<project-ref>`        | cms-api main container and the CLIs run in it with `kubectl exec`         | the owner (`supabase-owner-setup.md`, step 3); the owner sets its password        |
| `abyss_backup`       | `abyss_backup.<project-ref>`     | the nightly backup CronJob                                                | the roles script; the operator sets its password with `\password` (step S4 below) |

Rights, as the roles script grants them in `hosting=supabase` mode:

- `abyss_api`: `SELECT, INSERT, UPDATE, DELETE` on the tables and `USAGE, SELECT` on the sequences of schemas `public` and `content`, plus `USAGE` on both schemas. It has no `CREATE`, so it cannot run DDL. On `_prisma_migrations`, `content._migrations` and `content._content_types` it has `SELECT` only, because the runtime reads masking flags such as `sensitive: true` from `_content_types`, and a runtime that could write them could unmask fields.
- `abyss_backup`: explicit `SELECT` on every table and sequence of `public` and `content`, `USAGE` on both schemas, nothing else. It does not use `pg_read_all_data`, which `postgres` may not be allowed to grant.
- `postgres`: the migrator. The init container holds its password, in a Secret that no other pod mounts. That is the accepted trade-off of ADR 0012 section 9.2.
- `anon`, `authenticated`, `service_role`: the script revokes every privilege they hold on the tables, sequences and functions of `public` and `content`, and removes them from the default privileges of `postgres` for new objects.

A login role used through the pooler needs a password and no expired `VALID UNTIL`. A role with an expired date, or without a password, fails with `EAUTHQUERY`. If `abyss_api` suddenly cannot connect, check both in `pg_roles` first (`rolvaliduntil`, `rolcanlogin`).

## 3. Runbook, once per project (steps S1 to S8)

The step names are those of ADR 0012 section 9.6 and `devops-runbook.md` section 5. Run S1 to S4 and S6 from a workstation with `psql` 17 and the CA file, never from a pod.

Values to copy from the dashboard (Connect > Session pooler): `<project-ref>` and `<pooler-host>`. Below, `<conn>` stands for this connection string with the migrator user:

```sh
<conn> = "host=<pooler-host> port=5432 dbname=postgres user=postgres.<project-ref> sslmode=verify-full sslrootcert=<path to ca.crt>"
```

**S1. Dashboard (owner).** Do these in the dashboard; the owner guide `supabase-owner-setup.md` (steps 1, 2, 4) walks through each one with its own check:

- Data API off ("Enable Data API" off), and "Automatically expose new tables" off where it is still shown. Reason: section 1.
- Database settings, SSL: "Enforce SSL on incoming connections" on, then download the CA certificate. The CA is public.
- Network restrictions to the VPS egress address, if the plan offers them.

Turn "Enforce SSL" on only when the cms-api image with the TLS keys is deployed and `DB_SSL_MODE=verify-full` is set, or the app cannot connect (section 4). A project that is still empty can enable it at once.

**S2. Prove the CA and the host name.**

```sh
psql "<conn>" -c 'select version()'
```

It must print one line `PostgreSQL 17...`. With `sslmode=verify-full` this proves the CA file and that the host matches the certificate. It asks for the `postgres` password at the prompt. The same command with `sslmode=disable` must be refused; that is the proof that "Enforce SSL" is on.

**S3. Roles script, first run.** Run it as `postgres` itself, through the pooler:

```sh
psql "<conn>" -v ON_ERROR_STOP=1 \
  -v hosting=supabase -v migrator_role=postgres \
  -v api_role=abyss_api -v backup_role=abyss_backup \
  -v data_api_roles=anon,authenticated,service_role \
  -f scripts/db/database-roles.sql
```

- The script is idempotent. It creates `abyss_backup` (login, no password) and resets the attributes of `abyss_api` and `abyss_backup`; an existing role keeps its password. It creates schema `content` if missing, sets the grants and default privileges for objects `postgres` creates, revokes the Data API roles, and ends with a self-check that raises an error (no values printed) when a rule above is broken.
- Variable names are the plain role names. Do not put the `.<project-ref>` suffix in any `-v` value.
- It never changes the database owner and never revokes anything from `PUBLIC`, because Supabase's own services use the same database.
- Not checked in this mode: `TEMPORARY` on the database stays with `PUBLIC`, so `abyss_api` can create temporary tables (they live in the session only). Accepted, section 7. If the self-check finds `CREATE` on schema `public` for the API role through `PUBLIC`, it fails and you report it; the script does not revoke it silently.

**S4. Password of the backup role.** Open `psql "<conn>"` without `-c` and type at the prompt:

```
\password abyss_backup
```

Use a value from `openssl rand -base64 32`. `psql` asks twice and prints nothing. Store it only in the encrypted `postgres-backup` Secret. Never put it in a file, a command line or a ticket. `abyss_api` already has the password the owner set; if it has none yet, run `\password abyss_api` the same way.

**S5. Deploy.** Write the two ConfigMaps and three Secrets of section 5 with SOPS in the deploy repo, let Flux apply them and roll out cms-api. The init container migrates as `postgres`. Deploy order and what to check: `devops-runbook.md` section 7.

**S6. Roles script, second run.** Run the S3 command again. It must end without error: the migrations have created the meta tables, so they are now restricted to `SELECT` for `abyss_api`, and the self-check proves it. A missed second run shows up here.

**S7. Check after deploy.**

- `curl -fsS https://<domain>/api/v1/health/ready` returns `{"status":"ok"}`.
- `kubectl -n <ns> logs deploy/cms-api -c cms-api` has no warning that the database role can change the schema (section 6).
- `curl -sS "https://<project-ref>.supabase.co/rest/v1/" -H "apikey: <anon-key>"` answers an error and lists no app table.

**S8. Rotation.** `\password abyss_api` or `\password abyss_backup` at a psql prompt; rotate the `postgres` password in the dashboard. Then update the matching Secret (`k3s-secrets-sops.md` section 7) and restart the workload that uses it: cms-api with `rollout restart`, the migrator at the next rollout, the backup job at its next run.

## 4. TLS from cms-api

Two keys in the ConfigMap `cms-api-config`, read by the init container and the main container. Neither is a secret.

| Key                     | Value in production             | Meaning                                                                                                                                               |
| ----------------------- | ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DB_SSL_MODE`           | `verify-full`                   | `disable` is the default and only for local stacks. `require` encrypts without checking the server and is not used in production.                     |
| `DB_SSL_ROOT_CERT_PATH` | `/etc/abyss/database-ca/ca.crt` | Absolute path of the mounted CA (PEM), required with `verify-full`. A missing, unreadable or non-PEM file stops the process at boot, naming this key. |

- The CA from the dashboard goes into the ConfigMap `database-ca` (key `ca.crt`) and is mounted read-only at `/etc/abyss/database-ca` in the init container, the main container and the backup job.
- `DB_HOST` must be the pooler host exactly as in the certificate. An IP address or an alias that the certificate does not list fails `verify-full`.
- `prisma migrate deploy` gets the same settings from the same two keys (`apps/cms-api/README.md`, "Database TLS").
- The backup job uses the libpq names for the same CA: `PGSSLMODE=verify-full` and `PGSSLROOTCERT=/etc/abyss/database-ca/ca.crt`.

## 5. Secret map

Names only; the values live in SOPS-encrypted files in the deploy repo (`k3s-secrets-sops.md`). There is no `postgres-superuser` Secret and no StatefulSet on Supabase.

| Object                      | Keys                                                                                                                                      | Mounted into                          |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| ConfigMap `cms-api-config`  | `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH`, the other non-secret keys; **no** `DB_USERNAME`                  | init container and main container     |
| ConfigMap `database-ca`     | `ca.crt`                                                                                                                                  | init, main, backup (read-only volume) |
| Secret `cms-api-secrets`    | `DB_USERNAME=abyss_api.<project-ref>`, `DB_PASSWORD`, the app secrets, `BACKUP_STORAGE_ACCESS_KEY_ID`, `BACKUP_STORAGE_SECRET_ACCESS_KEY` | main container only                   |
| Secret `cms-api-migrate-db` | `DB_USERNAME=postgres.<project-ref>`, `DB_PASSWORD`                                                                                       | init container only                   |
| Secret `postgres-backup`    | `DB_USERNAME=abyss_backup.<project-ref>`, `DB_PASSWORD`, the rclone remote settings, `BACKUP_AGE_RECIPIENT`                               | backup CronJob only                   |

The init container reads only the database part of the config (the migration commands load `DB_*` and `NODE_ENV`), so it needs no app secret. The main container never sees the migrator password: containers in a pod do not share environments, and the init container has exited before the main one starts.

Until the S3 to S6 steps are done, the deploy may run in mode A of `devops-runbook.md` section 4.6 (both containers use `postgres.<project-ref>`). That needs the owner's written acceptance, and cms-api then logs the warning of section 6 on every start.

## 6. Boot warning for a role that can run DDL

With `NODE_ENV=production`, cms-api checks its own database role once at boot and logs one warning when the role is a superuser, has `CREATE` on the database, has `CREATE` on `public` or `content`, or owns objects in them. The warning starts with "The database role can change the schema" and names only the problems, never a value. It never blocks the start.

- Expected in mode A (shared `postgres` account).
- Not expected as `abyss_api`. If it appears there, the roles script has not run, or a grant was added by hand: run S3 and read the self-check.
- "Could not check whether the database role can change the schema" means the check query failed (for example the database was unreachable at boot); read the log lines around it.

## 7. Backups on Supabase

The free plan has no automatic backups and a 500 MB database limit, so the nightly dump is the only copy that survives the project. The design is ADR 0013; the job manifest, the bucket rules and the restore drill are in `k3s-traefik.md` section 7. What is specific to Supabase:

- **Role and connection.** The job connects as `abyss_backup.<project-ref>` through the session pooler (host and port from `cms-api-config`, database `postgres`) with `PGSSLMODE=verify-full` and the mounted CA.
- **Which schemas.** `pg_dump -Fc -n public -n content`. `abyss_backup` cannot read Supabase's own schemas, and the dump must not contain them. The dump holds the whole app: accounts, audit logs, media rows, content and its migration history.
- **Client version.** The backup image has `pg_dump` and `psql` 17 or newer.
- **Pre-dump size check.** The job reads `pg_database_size` and warns above `BACKUP_MAX_DATABASE_BYTES` (400 MB, 80 percent of the free limit). It still dumps and then exits 1 so the failure alert fires.
- **Restore drill.** Never against the live project. Restore into a local `postgres:17` container: run the roles script there in `hosting=self_managed` mode first, create the scratch database owned by the migrator role, `pg_restore --no-owner` as the migrator, then `deploy:migrate` against it must print "No pending ..." twice. This proves the dump, not the Supabase restore. The commands are in `k3s-traefik.md` section 7. The first step is `age -d`, because the dumps are encrypted.
- **Disaster restore into a new project.** Run S1 to S4 on the new project first, then `pg_restore --no-owner -n public -n content` as `postgres`, then roll out; the init container confirms the schema is current.
- **Download from the admin.** The owner can list and download the encrypted dumps on the cms-admin Backups page (password plus 2FA code). It needs the six `BACKUP_STORAGE_*` keys of `k3s-traefik.md` section 7, "Backup download".

## 8. The free plan and accepted risks

- **Pause.** A free project pauses after 7 days of low activity (accepted for launch, Q-DB6). While it is paused, `/health/ready` fails and the site shows errors. Watch the warning e-mail from Supabase; restore the project in the dashboard, then `kubectl -n <ns> rollout restart deploy/cms-api` if readiness does not recover by itself.
- **Init container holds the `postgres` password.** It lives only in `cms-api-migrate-db`, which only the init container mounts.
- **Temporary tables.** `PUBLIC` keeps `TEMPORARY` on the database, so `abyss_api` can create session-local temporary tables.
- **Other login roles can connect.** `PUBLIC` keeps `CONNECT`; only Supabase's own roles and ours exist on the project.
- **Connection budget.** One cms-api pod can open up to three `pg` pools of up to 10 connections, and a rollout runs two pods at once. Compare the total with the session pooler's pool size (dashboard > Database > Connection pooling) before launch. Not yet checked (`devops-runbook.md` section 5).
- **DDL against the real project.** Nothing from the smoke stack proves Supabase-specific grants. S3, S6 and S7 on the real project are that proof.
