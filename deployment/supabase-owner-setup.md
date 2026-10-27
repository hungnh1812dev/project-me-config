# Cài đặt Supabase cho owner (hướng dẫn ngắn)

Hướng dẫn này dành cho owner. Bạn làm từng bước theo thứ tự, trong Supabase dashboard và SQL Editor, cộng một lần kiểm tra bằng `psql` trên máy của bạn. Mỗi bước kết thúc bằng **một phép kiểm tra**. Chỉ sang bước sau khi kiểm tra đó đạt.

Nguồn: `docs/deployment/devops-runbook.md` §5 (bước S1, S2) và ADR 0012 §9 (`docs/adr/0012-database-role-separation.md`). Phần còn lại cho đội devops (script phân quyền S3, S4, S6, kiểm tra sau deploy S7, đổi mật khẩu S8) nằm trong runbook §5.

Quy tắc chung:

- Không bao giờ ghi mật khẩu hay khóa bí mật vào file này, vào git (trừ dạng đã mã hóa SOPS), vào chat hay ticket.
- Các giá trị trong `<...>` là chỗ để bạn điền. Thay bằng giá trị thật **chỉ trên máy của bạn** hoặc trong Secret đã mã hóa.
- Tên menu trong dashboard có thể đổi theo thời gian. Nếu không thấy đúng tên, tìm theo từ khóa trong ngoặc kép.

## Bước 0. Chuẩn bị

1. Máy của bạn có `psql` bản 17. Kiểm tra: `psql --version` in ra `17.x`.
2. Đã có Supabase project. Ghi lại hai giá trị (không phải bí mật, nhưng chỉ ghi trên máy bạn):
   - `<project-ref>`: mã project, có trong URL của dashboard (`https://supabase.com/dashboard/project/<project-ref>`).
   - Mật khẩu database của project (của role `postgres`). Nếu quên, đặt lại trong phần cài đặt Database của project ("Reset database password").

**Kiểm tra:** bạn có `psql` 17, biết `<project-ref>` và mật khẩu database.

## Bước 1. Bật "Enforce SSL" và tải chứng chỉ CA

1. Vào cài đặt Database của project, mục SSL ("SSL Configuration").
2. Bật **"Enforce SSL on incoming connections"**.
3. Bấm tải chứng chỉ CA ("Download certificate"). Lưu file với tên `ca.crt` trên máy bạn. Chứng chỉ này là công khai, không phải bí mật. Nó sẽ được đưa vào ConfigMap `database-ca` ở bước 6.

Lưu ý: khi "Enforce SSL" bật, mọi kết nối không mã hóa đều bị từ chối. Ứng dụng chỉ kết nối được khi đã chạy image có cấu hình TLS (`DB_SSL_MODE=verify-full`). Với project mới, chưa có gì chạy, bạn bật ngay được.

**Kiểm tra:** làm sau bước 4 (khi đã có `<pooler-host>`), lệnh không có SSL phải bị **từ chối**:

```sh
psql "host=<pooler-host> port=5432 dbname=postgres user=postgres.<project-ref> sslmode=disable" -c 'select 1'
```

Kết quả mong đợi: lỗi kết nối (server yêu cầu SSL). Nếu lệnh chạy được, "Enforce SSL" chưa bật.

## Bước 2. Tắt Data API

1. Vào cài đặt "Data API" của project.
2. Tắt **"Enable Data API"**.
3. Nếu còn thấy tùy chọn **"Automatically expose new tables"**, tắt luôn.
4. Nếu gói của bạn có "Network Restrictions", giới hạn kết nối chỉ từ địa chỉ IP của VPS. Gói không có thì bỏ qua.

Lý do (một dòng): khi Data API bật, ai có anon key cũng có thể đọc và ghi thẳng vào bảng của app, bỏ qua mọi quy tắc của cms-api.

**Kiểm tra:** gọi Data API bằng anon key (lấy trong phần API keys của project) không trả về bảng nào của app:

```sh
curl -sS "https://<project-ref>.supabase.co/rest/v1/" -H "apikey: <anon-key>"
```

Kết quả mong đợi: một lỗi (Data API đã tắt), không có danh sách bảng.

## Bước 3. Tạo login role `abyss_api`

`abyss_api` là role mà cms-api dùng khi chạy. Ở bước này bạn chỉ tạo role, **chưa đặt mật khẩu**. Mật khẩu đặt ở bước 5 bằng `psql`, để nó không nằm trong lịch sử của SQL Editor.

Nếu `abyss_api` đã có (bạn đã tạo trước đó), bỏ qua phần tạo và chỉ chạy phần kiểm tra.

1. Mở **SQL Editor** trong dashboard.
2. Chạy:

```sql
create role abyss_api login nosuperuser nocreatedb nocreaterole nobypassrls noreplication;
```

Role này chưa có quyền gì trên bảng của app. Quyền được cấp sau bởi script `scripts/db/database-roles.sql` (runbook §5, bước S3). Việc đó là của đội devops.

**Kiểm tra:** trong SQL Editor:

```sql
select rolname, rolcanlogin, rolsuper, rolvaliduntil from pg_roles where rolname = 'abyss_api';
```

Kết quả mong đợi: một dòng, `rolcanlogin = true`, `rolsuper = false`, `rolvaliduntil` rỗng (không hết hạn). Role có ngày hết hạn đã qua sẽ không đăng nhập được qua pooler.

## Bước 4. Lấy thông tin kết nối Session pooler

1. Bấm nút **"Connect"** ở đầu trang project.
2. Chọn **"Session pooler"** (không chọn "Direct connection", không chọn "Transaction pooler").
3. Ghi lại host, ví dụ dạng `<pooler-host>`. Đó là giá trị cho `DB_HOST`.

Ba điều phải đúng:

| Mục           | Giá trị                                                                                                   |
| ------------- | --------------------------------------------------------------------------------------------------------- |
| Port          | `5432`. **Không bao giờ dùng `6543`** (transaction pooler làm hỏng migrate).                              |
| Database      | `postgres`                                                                                                |
| Tên đăng nhập | luôn có hậu tố project: `<role>.<project-ref>`, ví dụ `postgres.<project-ref>`, `abyss_api.<project-ref>` |

Hậu tố `.<project-ref>` chỉ dùng trong tên đăng nhập. Bên trong database, role vẫn tên là `abyss_api` (không có hậu tố).

**Kiểm tra:** chuỗi kết nối hiển thị trong mục "Session pooler" có port `5432` và user dạng `postgres.<project-ref>`.

## Bước 5. Kiểm tra bằng `psql` với `verify-full` và đặt mật khẩu `abyss_api`

Chạy trong thư mục có file `ca.crt` (hoặc ghi đường dẫn đầy đủ tới nó).

1. Kết nối bằng role `postgres`, có kiểm tra chứng chỉ:

```sh
psql "host=<pooler-host> port=5432 dbname=postgres user=postgres.<project-ref> sslmode=verify-full sslrootcert=ca.crt" -c 'select version()'
```

`psql` sẽ hỏi mật khẩu database. Kết quả mong đợi: một dòng `PostgreSQL 17...`. Lệnh này chứng minh CA đúng và host khớp với chứng chỉ.

2. Đặt mật khẩu cho `abyss_api`. Tạo một mật khẩu mạnh trên máy bạn (ví dụ `openssl rand -base64 32`) và cất vào trình quản lý mật khẩu. Sau đó mở `psql` với cùng chuỗi kết nối ở trên (bỏ phần `-c ...`) và gõ tại dấu nhắc:

```
\password abyss_api
```

`psql` hỏi mật khẩu hai lần và không in nó ra. Gõ `\q` để thoát. Nếu `abyss_api` đã có mật khẩu từ trước, bỏ qua bước này.

3. Kết nối bằng `abyss_api`:

```sh
psql "host=<pooler-host> port=5432 dbname=postgres user=abyss_api.<project-ref> sslmode=verify-full sslrootcert=ca.crt" -c 'select current_user'
```

**Kiểm tra:** lệnh 1 in ra `PostgreSQL 17`, và lệnh 3 in ra `abyss_api`. Nếu lệnh 3 báo `EAUTHQUERY` hoặc sai mật khẩu, kiểm tra lại bước 3 (role có `login`, không hết hạn) và bước 5.2.

## Bước 6. Những gì chuyển cho deploy secrets

Chỉ tên khóa và chỗ để điền. Giá trị thật chỉ nằm trong Secret đã mã hóa SOPS ở deploy repo (`docs/deployment/k3s-secrets-sops.md`), không bao giờ ở dạng chữ thường trong git.

ConfigMap `cms-api-config` (không phải bí mật):

| Khóa                    | Giá trị                         |
| ----------------------- | ------------------------------- |
| `DB_HOST`               | `<pooler-host>` (bước 4)        |
| `DB_PORT`               | `5432`                          |
| `DB_NAME`               | `postgres`                      |
| `DB_SSL_MODE`           | `verify-full`                   |
| `DB_SSL_ROOT_CERT_PATH` | `/etc/abyss/database-ca/ca.crt` |

ConfigMap `database-ca` (không phải bí mật):

| Khóa     | Giá trị                             |
| -------- | ----------------------------------- |
| `ca.crt` | nội dung file `ca.crt` tải ở bước 1 |

Secret `cms-api-secrets` (container chính `cms-api`):

| Khóa          | Giá trị                          |
| ------------- | -------------------------------- |
| `DB_USERNAME` | `abyss_api.<project-ref>`        |
| `DB_PASSWORD` | `<mật khẩu abyss_api, bước 5.2>` |

Secret `cms-api-migrate-db` (chỉ init container `migrate`):

| Khóa          | Giá trị                           |
| ------------- | --------------------------------- |
| `DB_USERNAME` | `postgres.<project-ref>`          |
| `DB_PASSWORD` | `<mật khẩu database của project>` |

Lưu ý: `abyss_api` chỉ dùng được sau khi đội devops chạy script phân quyền (runbook §5, S3). Trước đó, đội devops có thể tạm dùng `postgres.<project-ref>` trong `cms-api-secrets` (chế độ A, runbook §4.6), và việc này cần bạn chấp nhận bằng văn bản. Role `abyss_backup` và Secret `postgres-backup` do script tạo sau, không thuộc hướng dẫn này.

**Kiểm tra:** đội devops xác nhận đã nhận đủ 4 đối tượng trên (`cms-api-config`, `database-ca`, `cms-api-secrets`, `cms-api-migrate-db`), mỗi Secret đã mã hóa SOPS trước khi commit, và không có mật khẩu nào được gửi qua chat hay ticket.
