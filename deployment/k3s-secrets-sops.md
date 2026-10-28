# K3s secrets with SOPS

How the secret values of Abyss reach the cluster without ever being committed in plain text. Builds on `docs/deployment/k3s-traefik.md` (images, routing, the full cms-api env contract in its section 6); this guide does not repeat that table, it adds the secret-handling side. Like that guide, the files below live in the **deploy repo**, not here.

Status: nothing here was run against a cluster (no cluster available). The `sops` and `age` commands and the Flux/Argo notes follow their documented behaviour; test the flow once on a scratch namespace before relying on it.

## 1. Which keys are secret

| App       | Secret keys (go in the encrypted Secret)                                                                                                                                                                                                                                                                                              | Not secret                                                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| cms-api   | `DB_USERNAME`, `DB_PASSWORD`, `JWT_ACCESS_SECRET`, `OTP_PEPPER`, `TOTP_ENC_KEY`, `CLOUDINARY_API_SECRET`, `TURNSTILE_SECRET_KEY`, `SMTP_USER`, `SMTP_PASSWORD`, `BACKUP_STORAGE_ACCESS_KEY_ID`, `BACKUP_STORAGE_SECRET_ACCESS_KEY`, `TOTP_ENC_PREVIOUS_KEY` (only during a rotation), `OWNER_SETUP_TOKEN` (only during first install) | everything else in `apps/cms-api/.env.example`: put it in the ConfigMap |
| web       | none                                                                                                                                                                                                                                                                                                                                  | all of `apps/web/.env.example` (`NEXT_PUBLIC_*` are public by design)   |
| cms-admin | none                                                                                                                                                                                                                                                                                                                                  | `VITE_API_BASE_URL` (build arg), `CSP_CONNECT_SRC`                      |

The database credentials are split by pod (ADR 0012 section 3). Four Secrets hold database logins, and a pod gets only the pair it needs:

| Secret               | Database keys                                                                                     | Mounted into                                                  |
| -------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `cms-api-secrets`    | `DB_USERNAME` = the API role `abyss_api`, `DB_PASSWORD`                                           | main container `cms-api` only                                 |
| `cms-api-migrate-db` | `DB_USERNAME` = the migration role (`abyss_migrator`; on Supabase `postgres`), `DB_PASSWORD`      | init container `migrate` only                                 |
| `postgres-backup`    | `DB_USERNAME` = `abyss_backup`, `DB_PASSWORD`, the rclone remote settings, `BACKUP_AGE_RECIPIENT` | backup CronJob only                                           |
| `postgres-superuser` | `POSTGRES_USER`, `POSTGRES_PASSWORD`                                                              | the in-cluster Postgres StatefulSet only; **not on Supabase** |

On Supabase there is no `postgres-superuser`, and every `DB_USERNAME` carries the project suffix: `abyss_api.<project-ref>`, `postgres.<project-ref>`, `abyss_backup.<project-ref>`. The ConfigMap `database-ca` (the public CA certificate) is mounted read-only into the init container, the main container and the backup job. The full Supabase map: `docs/deployment/supabase-database.md` section 5.

Notes:

- `SMTP_USER` and `SMTP_PASSWORD` are set both or neither. `CLOUDINARY_API_SECRET` is required with `MEDIA_PROVIDER=cloudinary`. `TURNSTILE_SECRET_KEY` unset makes `POST /reviewer/sessions` answer 503. `JWT_ACCESS_SECRET`, `OTP_PEPPER` and `TOTP_ENC_KEY` must each be at least 32 bytes (`openssl rand -base64 48`).
- `OWNER_SETUP_TOKEN` is optional and temporary: it opens the one-time owner setup page. Add it for the first install (at least 32 bytes in production, `openssl rand -base64 32`), create the owner, then remove it and restart. See "First install: the owner" in `docs/deployment/k3s-traefik.md`.
- The key ids (`JWT_ACCESS_KID`, `TOTP_ENC_KID`, `TOTP_ENC_PREVIOUS_KID`) are labels, not secrets; keep them in the ConfigMap.
- The Turnstile **site** key is public and is a web build arg, not a cluster secret.
- Other secrets exist outside the cluster and are not covered by this file: `DEPLOYMENT_REPO_TOKEN` and the registry login live in GitHub Environments (`docs/ci-cd.md`). The backup job has its own Secret `postgres-backup` (the write-capable bucket token and the database login); cms-api never holds it. `BACKUP_STORAGE_ACCESS_KEY_ID` and `BACKUP_STORAGE_SECRET_ACCESS_KEY` in `cms-api-secrets` are a different, read-only token (list and get) of the same bucket (`docs/deployment/k3s-traefik.md` section 7).
- `BACKUP_AGE_RECIPIENT` is a public key, but it stays with the job's other config in `postgres-backup`. The matching private age key is never in the cluster or in git (offline, two copies).
- Never use the Cloudflare always-pass test keys, `console` mail or `fake` media outside test stacks; production boot rejects the last two.

## 2. Layout in the deploy repo

```
.sops.yaml                          # which files are encrypted, to which keys
clusters/<env>/
  config/cms-api-config.yaml        # ConfigMap, plain (no secrets)
  secrets/cms-api-secrets.sops.yaml # Secret, encrypted (SOPS): API role + app secrets
  secrets/cms-api-migrate-db.sops.yaml # Secret, encrypted: the migration role (init container only)
  secrets/postgres-backup.sops.yaml # Secret, encrypted: backup role + bucket write token (backup job only)
  ...                               # Deployments, IngressRoutes (k3s guide)
```

One encrypted Secret per consumer that has secrets (cms-api, its init container, the backup job), one set of files per environment (`staging`, `production`), so a staging key never opens production. Web and admin get no Secret.

`.sops.yaml` (keep the real age public keys in place of the placeholders; a public key is safe to commit):

```yaml
creation_rules:
  - path_regex: clusters/production/secrets/.*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: <age-public-key-of-production-cluster>,<age-public-key-of-the-operator>
  - path_regex: clusters/staging/secrets/.*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: <age-public-key-of-staging-cluster>,<age-public-key-of-the-operator>
```

`encrypted_regex` leaves `metadata` (name, namespace) readable, so reviews and diffs show which Secret changed, but never a value. Adding the operator's key lets a person edit the file; the cluster key lets the cluster decrypt it.

The Secret, before encryption (use `stringData` so you do not base64 anything):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cms-api-secrets
  namespace: <namespace>
type: Opaque
stringData:
  DB_USERNAME: <abyss_api, on Supabase abyss_api.<project-ref>>
  DB_PASSWORD: <value>
  JWT_ACCESS_SECRET: <value>
  OTP_PEPPER: <value>
  TOTP_ENC_KEY: <value>
  CLOUDINARY_API_SECRET: <value>
  TURNSTILE_SECRET_KEY: <value>
  SMTP_USER: <value>
  SMTP_PASSWORD: <value>
  BACKUP_STORAGE_ACCESS_KEY_ID: <value> # read-only bucket token; with the next key, or neither
  BACKUP_STORAGE_SECRET_ACCESS_KEY: <value>
  # OWNER_SETUP_TOKEN: <value>   # first install only; remove after the owner exists
```

The init container's Secret. It holds only the migration role, so the init container needs no app secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cms-api-migrate-db
  namespace: <namespace>
type: Opaque
stringData:
  DB_USERNAME: <abyss_migrator, on Supabase postgres.<project-ref>>
  DB_PASSWORD: <value>
```

The backup job's Secret. Names of the rclone remote `offsite` follow rclone's `RCLONE_CONFIG_<REMOTE>_<OPTION>` convention:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-backup
  namespace: <namespace>
type: Opaque
stringData:
  DB_USERNAME: <abyss_backup, on Supabase abyss_backup.<project-ref>>
  DB_PASSWORD: <value>
  RCLONE_CONFIG_OFFSITE_TYPE: s3
  RCLONE_CONFIG_OFFSITE_PROVIDER: Cloudflare
  RCLONE_CONFIG_OFFSITE_ENDPOINT: https://<account-id>.r2.cloudflarestorage.com
  RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID: <value>
  RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY: <value>
  RCLONE_CONFIG_OFFSITE_NO_CHECK_BUCKET: 'true'
  BACKUP_AGE_RECIPIENT: <age1... public key>
```

## 3. One-time setup

Install `sops` and `age` on the operator machine, then:

```
age-keygen -o cluster-production.agekey     # prints the public key (age1...)
age-keygen -o operator.agekey
```

- Put the **public** keys in `.sops.yaml`.
- Never commit an `.agekey` file. Add `*.agekey` to the deploy repo's `.gitignore`. Back up each private key separately (password manager or offline copy): losing the cluster key means every committed secret is unreadable and must be re-issued.
- Give the cluster its private key as a Secret created by hand, once (it is the only secret that is never in git):

  ```
  kubectl -n <flux-or-argo-namespace> create secret generic sops-age \
    --from-file=age.agekey=cluster-production.agekey
  ```

  Flux expects the data key to end in `.agekey`; check your tool's docs if you use another.

## 4. Create the encrypted file

```
export SOPS_AGE_KEY_FILE=operator.agekey          # path to your private key
cp secret-template.yaml clusters/production/secrets/cms-api-secrets.sops.yaml
# fill in the values in an editor, then:
sops --encrypt --in-place clusters/production/secrets/cms-api-secrets.sops.yaml
```

Or create it already encrypted: `sops clusters/production/secrets/cms-api-secrets.sops.yaml` opens your editor on a new file and encrypts on save (the creation rule in `.sops.yaml` picks the keys).

Check before committing: `grep -c ENC\\[ clusters/production/secrets/cms-api-secrets.sops.yaml` finds the encrypted values and no plain value appears with `git diff --cached`. Never commit the filled template.

Edit later with `sops <file>` (decrypts into your editor, re-encrypts on save). Read with `sops -d <file>`; do not redirect the output into the repo.

## 5. Getting the Secret into the cluster

Pick one:

- **Manual flow (works anywhere):** `sops -d clusters/production/secrets/cms-api-secrets.sops.yaml | kubectl apply -f -`, then restart (section 7).
- **Flux:** on the Kustomization that applies `clusters/production`, set `spec.decryption: { provider: sops, secretRef: { name: sops-age } }`. Flux decrypts at apply time and the plain Secret exists only in the cluster.
- **Argo CD:** needs a SOPS plugin (for example KSOPS) in the repo-server; set that up per its docs. The age key is mounted into the repo-server.

## 6. How the apps consume it

**cms-api: each container reads its own database Secret.** The pod template has the init container `migrate` (`npm run deploy:migrate`) and the main container `cms-api`, both from the same image tag. Both take the ConfigMap; each takes a different Secret:

```yaml
# init container `migrate`
envFrom:
  - configMapRef: { name: cms-api-config }
  - secretRef: { name: cms-api-migrate-db }
# main container `cms-api`
envFrom:
  - configMapRef: { name: cms-api-config }
  - secretRef: { name: cms-api-secrets }
```

This is already in the Deployment of the k3s guide (section 3). Why the split: `deploy:migrate` loads only the database part of the config (`DB_*` and `NODE_ENV`), so the init container needs no app secret, and the API role has no DDL right. Containers in one pod do not share process environments, and the init container has exited before the main container starts, so the main container never sees the migration password. Because each Secret holds its own `DB_USERNAME`, `envFrom` never has two sources for one key, and `DB_USERNAME` is not in `cms-api-config`. The main container fails to start, with a list of failing key names and no values, if a required secret is missing or shorter than 32 bytes; a wrong database login stops the init container (`Init:Error`).

Env values are read once at process start: after any Secret change, restart (section 7). `envFrom` of a Secret does not update a running container.

The owner is created through the setup page with `OWNER_SETUP_TOKEN` (see section 1), not a shell. Manual one-time jobs (`owner:bootstrap`, `owner:reset-2fa`) run with `kubectl exec` inside the running main container, so they already have the Secret in their environment; the password is typed at a prompt and never stored in a file.

**web:** no Secret and no `envFrom` of a Secret. Its `NEXT_PUBLIC_*` values are build arguments (GitHub Environment variables) and its runtime values (`API_INTERNAL_URL`, `WEB_REVALIDATE_SECONDS`) are plain `env` entries. The server calls cms-api anonymously.

Note: In this repo (`apps/web`), web loads the Secret `web-secrets` through `envFrom`: `API_INTERNAL_URL` and `WEB_REVALIDATE_SECONDS`. The plain-`env` description here is the reference design, not what this repo deploys.

**cms-admin:** no Secret. `VITE_API_BASE_URL` is a build arg and `CSP_CONNECT_SRC` an optional plain env value.

## 7. Rotate

General steps for any secret: `sops <file>`, change the value, commit, apply (section 5), then restart so the pods read it:

```
kubectl -n <namespace> rollout restart deploy/cms-api
kubectl -n <namespace> rollout status deploy/cms-api
```

The restart also reruns the init container, so a wrong migration password shows up as `Init:Error` while the old pod keeps serving (`maxUnavailable: 0`). Look at `kubectl logs <pod> -c migrate`.

| Secret                       | How                                                                                                                                                                                                                                                                                        | Effect to expect                                                                                                               |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `DB_PASSWORD` (API role)     | change the role password at a psql prompt first (`\password abyss_api`), then `cms-api-secrets`, then restart cms-api. Never put the password in a SQL file.                                                                                                                               | brief gap between the two steps; do them back to back                                                                          |
| `DB_PASSWORD` (migrator)     | `\password abyss_migrator` (Supabase: reset the `postgres` password in the dashboard), then `cms-api-migrate-db`. Nothing to restart: the next rollout's init container reads it.                                                                                                          | a rollout between the two steps fails in the init container while the old pod keeps serving                                    |
| `DB_PASSWORD` (backup role)  | `\password abyss_backup`, then `postgres-backup`. No restart: the next scheduled run takes it.                                                                                                                                                                                             | one night's dump fails if the two steps are far apart                                                                          |
| bucket tokens                | rotate in the Cloudflare dashboard: the job token in `postgres-backup`, the read-only token in `cms-api-secrets` (`BACKUP_STORAGE_*`, restart cms-api). Roll the age key by generating a new pair and changing `BACKUP_AGE_RECIPIENT`; keep the old private key for the dumps already made | the Backups page shows an error between the two steps; the next dump fails with a wrong job token                              |
| `JWT_ACCESS_SECRET`          | new value and a new `JWT_ACCESS_KID` (ConfigMap) together, restart                                                                                                                                                                                                                         | there is no previous-key slot for the access secret, so existing access tokens stop validating; users sign in or refresh again |
| `OTP_PEPPER`                 | new value, restart                                                                                                                                                                                                                                                                         | one-time codes issued before the change no longer verify; users request a new code                                             |
| `TOTP_ENC_KEY`               | move the old key to `TOTP_ENC_PREVIOUS_KEY`, its id to `TOTP_ENC_PREVIOUS_KID`, set the new key and a new `TOTP_ENC_KID`, restart. Remove the previous pair after every user has signed in with a valid code once (each secret is re-encrypted on its next valid code)                     | no user is locked out; the previous pair must be set both or neither and its id must differ from the current one               |
| `CLOUDINARY_API_SECRET`      | rotate in the Cloudinary console, update the Secret, restart                                                                                                                                                                                                                               | uploads fail between the two steps                                                                                             |
| `TURNSTILE_SECRET_KEY`       | rotate in the Cloudflare dashboard, update, restart                                                                                                                                                                                                                                        | reviewer sessions fail between the two steps                                                                                   |
| `OWNER_SETUP_TOKEN`          | not rotated: replace it with a new value and restart if it leaked before setup, and remove it once the owner exists                                                                                                                                                                        | the old token stops working at once; with no owner yet the new one opens setup, with an owner the route stays closed (404)     |
| `SMTP_USER`, `SMTP_PASSWORD` | rotate at the mail provider, update both, restart                                                                                                                                                                                                                                          | OTP mail fails between the two steps                                                                                           |

Rotate the **age keys** separately from the values:

1. Generate the new key pair (section 3) and add its public key to `.sops.yaml` next to the old one.
2. Re-encrypt every file for the new recipient set: `sops updatekeys clusters/production/secrets/cms-api-secrets.sops.yaml`. Rotate the data key too with `sops --rotate --in-place <file>` when someone who held the old key should no longer be trusted. Then also rotate the secrets themselves: a leaked key can read every earlier commit.
3. Replace the `sops-age` Secret in the cluster with the new private key, confirm the apply still works, then remove the old public key from `.sops.yaml` and run `updatekeys` again.

If a private key or a decrypted value leaks: rotate every value it covered (table above), then the age key.

## 8. Rules of thumb

- Plain secrets only ever exist in the cluster and in the operator's editor buffer.
- CI in the app repo holds no cluster secrets; it only bumps `APP_IMAGE_TAG` in the deploy repo (`docs/ci-cd.md`).
- Review a secret change by its commit metadata and the key names in the diff; SOPS leaves keys readable and values encrypted.
- Back up the private age keys, the Postgres dumps, and know how to rebuild (k3s guide, section 7): a cluster rebuild needs the age key before anything encrypted can be applied.
