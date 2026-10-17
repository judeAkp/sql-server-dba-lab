# Project 03 — Security Hardening Baseline

**Status:** ✅ Complete · **Completed:** October 2026

---

## Objective

Take a default SQL Server 2022 Developer Edition instance and harden it to a documented production baseline: disable `sa`, verify surface-area configuration, enforce least-privilege access across three custom database roles, detect and remap orphaned users, implement `AES_256` Transparent Data Encryption (TDE) and encrypted backups with verified certificate backups, enable SQL Server Audit, and implement UK GDPR Dynamic Data Masking.

---

## Threat Model & Controls Implemented

| Risk | Mitigation Implemented & Verified |
|---|---|
| Over-privileged application & analyst accounts | Custom roles (`db_reporting`, `db_application`, `db_support`) tested via `EXECUTE AS USER`; no `db_owner` or `sysadmin` for apps |
| Brute-force attacks against default SQL admin | Disabled `[sa]` login (`ALTER LOGIN [sa] DISABLE`); Windows authentication enforced for `sysadmin` |
| OS command / COM execution from SQL injection | Verified `xp_cmdshell = 0`, `Ole Automation Procedures = 0`, `Ad Hoc Distributed Queries = 0`, `cross db ownership chaining = 0` |
| Broken application logins after DR restore | Simulated SID mismatch on `[app_legacy_svc]`, detected via `sys.database_principals`, and remapped via `ALTER USER ... WITH LOGIN` |
| Theft of `.mdf`/`.ldf` or `.bak` media at rest | Enabled `AES_256` TDE + native `AES_256` backup encryption (`TDECert_2026`), with `.cer` and encrypted `.pvk` backed up to `C:\SQLBackup\Certs\` |
| Unaccountable privilege or schema changes | Enabled `SERVER AUDIT` (`DBA_Lab_Audit`) + `SERVER AUDIT SPECIFICATION` logging to `C:\SQLAudit\*.sqlaudit` |
| Personal data (PII) exposure to reporting users | Implemented Dynamic Data Masking on UK customer PII (`FullName`, `EmailAddress`, `NationalInsuranceNo`, `SalaryGBP`) |

The repeatable verification script is committed at [`scripts/security/01-security-hardening-lab.sql`](../scripts/security/01-security-hardening-lab.sql), and verbatim SSMS output is saved in [`evidence/security-hardening-verification.txt`](../evidence/security-hardening-verification.txt).

---

## 1. Server-Level Hardening & Surface-Area Audit

```sql
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

SELECT
    name,
    CAST(value AS int)        AS configured_value,
    CAST(value_in_use AS int) AS running_value
FROM sys.configurations
WHERE name IN (
    N'xp_cmdshell',
    N'Ole Automation Procedures',
    N'Ad Hoc Distributed Queries',
    N'cross db ownership chaining',
    N'remote admin connections'
)
ORDER BY name;

-- Disable the built-in SQL [sa] account
ALTER LOGIN [sa] DISABLE;
```

**Measured Surface-Area Baseline (`sys.configurations` & `sys.server_principals`):**

| Configuration / Principal | Value / State | Security Assessment |
|---|---|---|
| `Ad Hoc Distributed Queries` | `0` (Disabled) | **PASS** — prevents ad-hoc `OPENROWSET` / `OPENDATASOURCE` |
| `cross db ownership chaining` | `0` (Disabled) | **PASS** — prevents cross-database privilege escalation |
| `Ole Automation Procedures` | `0` (Disabled) | **PASS** — blocks `sp_OACreate` COM execution |
| `xp_cmdshell` | `0` (Disabled) | **PASS** — blocks OS shell execution from T-SQL |
| `remote admin connections` | `0` (Local DAC only) | **PASS** — Dedicated Admin Connection restricted to local host |
| `[sa]` SQL Login | `is_disabled = 1` | **PASS** — `Action: Disabled [sa] login.` |

---

## 2. Least-Privilege Role Design & Live Impersonation Proof

Created three custom database roles in `StackOverflow2010` modelling realistic production access patterns:

```sql
USE StackOverflow2010;
GO

-- 1. Read-only reporting role
CREATE ROLE db_reporting;
GRANT SELECT ON SCHEMA::dbo TO db_reporting;

-- 2. Application CRUD role (explicitly blocked from schema modifications)
CREATE ROLE db_application;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO db_application;
DENY ALTER ON SCHEMA::dbo TO db_application;

-- 3. Support / 2nd-line DBA role (read data + inspect proc/view definitions, no writes)
CREATE ROLE db_support;
GRANT SELECT ON SCHEMA::dbo TO db_support;
GRANT VIEW DEFINITION ON SCHEMA::dbo TO db_support;
```

> **Critical permission-hierarchy lesson (`DENY CONTROL` vs `DENY ALTER`):**
> An initial version of `db_application` executed `DENY ALTER, CONTROL ON SCHEMA::dbo TO db_application`. In SQL Server's permission hierarchy, `CONTROL` is an umbrella permission that implies `SELECT`, `INSERT`, `UPDATE`, and `DELETE`. Because `DENY` always overrides `GRANT`, `DENY CONTROL` silently blocked `SELECT` and `UPDATE` with `Msg 229`! Replacing `DENY CONTROL` with `DENY ALTER ON SCHEMA::dbo` allowed normal CRUD while blocking `ALTER TABLE`.

**Measured Role Verification (`EXECUTE AS USER` in `StackOverflow2010`):**

| Role | Test User | Permitted Action Tested | Restricted Action Tested | Verbatim SSMS Output |
|---|---|---|---|---|
| **`db_reporting`** | `usr_reporting` | `SELECT COUNT(*) FROM dbo.Users WHERE Id = 1` | `UPDATE dbo.Users SET Reputation = Reputation + 1 WHERE Id = 1` | `PASS [db_reporting]: SELECT succeeded (rows=1).`<br>`PASS [db_reporting]: UPDATE blocked -> Msg 229: The UPDATE permission was denied on the object 'Users', database 'StackOverflow2010', schema 'dbo'.` |
| **`db_application`** | `usr_application` | `UPDATE dbo.Users SET LastAccessDate = LastAccessDate WHERE Id = 1` | `ALTER TABLE dbo.Users ADD UnauthorizedCol int NULL` | `PASS [db_application]: UPDATE succeeded.`<br>`PASS [db_application]: ALTER TABLE blocked -> Msg 1088: Cannot find the object "Users" because it does not exist or you do not have permissions.` |
| **`db_support`** | `usr_support` | `OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_GetBadgesByName'))` | `DELETE FROM dbo.Users WHERE Id = -999999` | `PASS [db_support]: VIEW DEFINITION succeeded (proc length=188).`<br>`PASS [db_support]: DELETE blocked -> Msg 229: The DELETE permission was denied on the object 'Users', database 'StackOverflow2010', schema 'dbo'.` |

---

## 3. Orphaned Users — Simulation, Detection & SID Remapping

**Why orphaned users happen:** Server logins live in `master` (`sys.server_principals`), while database users live inside the user database (`sys.database_principals`), linked by a binary **Security Identifier (`SID`)**. When a database is restored to a second server where the SQL login was created independently with `CREATE LOGIN`, the login name matches but the **`SID` does not**, causing `Login failed for user` (`Error 18456`).

### Simulation & Resolution Executed

1. Created server login `[app_legacy_svc]` and mapped database user `[app_legacy_svc]` in `StackOverflow2010`.
2. Dropped and recreated `[app_legacy_svc]` at the server level so it received a new `SID`, orphaning the database user.
3. Detected the orphaned user and remapped the `SID`:

```sql
-- 1. Detect orphaned users (database SID has no matching server login SID)
SELECT
    dp.name AS orphaned_db_user,
    dp.type_desc,
    dp.sid  AS db_user_sid,
    SUSER_SID(dp.name) AS server_login_sid
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE sp.sid IS NULL
  AND dp.type IN ('S', 'U', 'G')
  AND dp.authentication_type_desc <> 'NONE'
  AND dp.principal_id > 4;

-- 2. Remap the database user's SID to match the server login's SID
ALTER USER [app_legacy_svc] WITH LOGIN = [app_legacy_svc];

-- 3. Verify SIDs match (using COLLATE DATABASE_DEFAULT across UK server / US database)
SELECT
    dp.name AS remapped_db_user,
    dp.sid  AS db_user_sid,
    sp.sid  AS server_login_sid,
    CASE WHEN dp.sid = sp.sid THEN 'FIXED (SIDs match)' ELSE 'STILL ORPHANED' END AS status_after_fix
FROM sys.database_principals dp
JOIN sys.server_principals sp
    ON dp.name COLLATE DATABASE_DEFAULT = sp.name COLLATE DATABASE_DEFAULT
WHERE dp.name = N'app_legacy_svc';
```

> **UK Collation Lesson (`Msg 468`):** Joining `sys.database_principals.name` (`SQL_Latin1_General_CP1_CI_AS` on US-built `StackOverflow2010`) to `sys.server_principals.name` (`Latin1_General_CI_AS` on a UK Windows/SQL Server install) initially threw `Msg 468: Cannot resolve the collation conflict between "Latin1_General_CI_AS" and "SQL_Latin1_General_CP1_CI_AS"`. Adding `COLLATE DATABASE_DEFAULT` resolved the cross-collation catalog join cleanly.

---

## 4. Encryption at Rest — TDE & Native Backup Encryption (`SecVaultLab`)

### Transparent Data Encryption (`AES_256`)

```sql
USE master;
GO
EXEC sys.xp_create_subdir N'C:\SQLBackup\Certs';
GO

CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'<StrongMasterKeyPassword>';
CREATE CERTIFICATE TDECert_2026 WITH SUBJECT = N'SQL Server DBA Lab TDE Certificate 2026';

-- CRITICAL: Back up the certificate and private key BEFORE enabling TDE
BACKUP CERTIFICATE TDECert_2026
TO FILE = N'C:\SQLBackup\Certs\TDECert_2026.cer'
WITH PRIVATE KEY (
    FILE = N'C:\SQLBackup\Certs\TDECert_2026.pvk',
    ENCRYPTION BY PASSWORD = N'<StrongPrivateKeyPassword>'
);
GO

USE SecVaultLab;
GO
CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER CERTIFICATE TDECert_2026;
GO
ALTER DATABASE SecVaultLab SET ENCRYPTION ON;
GO
```

> **The career-saving rule:** Enabling TDE without backing up the server certificate (`.cer`) **and** its private key (`.pvk`) means that if the `master` database is lost, every `.mdf` and `.bak` of that database is permanently unrecoverable on any other server.

### Native Backup Encryption (`AES_256`)

```sql
BACKUP DATABASE SecVaultLab
TO DISK = N'C:\SQLBackup\FULL\SecVaultLab_Encrypted.bak'
WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = TDECert_2026),
     COMPRESSION, CHECKSUM, INIT;
```

**Measured Output:**
- `Created Database Master Key in master.`
- `Created Server Certificate TDECert_2026.`
- `Backed up TDECert_2026.cer and TDECert_2026.pvk to C:\SQLBackup\Certs\.`
- `sys.dm_database_encryption_keys`: both `SecVaultLab` and `tempdb` reported `encryption_state = 3 (ENCRYPTED)`, `key_algorithm = AES`, `key_length = 256`, `encryptor_cert = TDECert_2026`.
- `BACKUP DATABASE successfully processed 409 pages in 0.087 seconds (36.654 MB/sec).`

---

## 5. Accountability — SQL Server Audit (`sys.fn_get_audit_file`)

```sql
USE master;
GO
EXEC sys.xp_create_subdir N'C:\SQLAudit';
GO

CREATE SERVER AUDIT DBA_Lab_Audit
TO FILE (FILEPATH = N'C:\SQLAudit\', MAXSIZE = 50 MB, MAX_ROLLOVER_FILES = 5)
WITH (QUEUE_DELAY = 0, ON_FAILURE = CONTINUE);
GO
ALTER SERVER AUDIT DBA_Lab_Audit WITH (STATE = ON);
GO

CREATE SERVER AUDIT SPECIFICATION DBA_Lab_Server_Spec
FOR SERVER AUDIT DBA_Lab_Audit
    ADD (FAILED_LOGIN_GROUP),
    ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
    ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
    ADD (DATABASE_PERMISSION_CHANGE_GROUP),
    ADD (SCHEMA_OBJECT_CHANGE_GROUP)
WITH (STATE = ON);
GO
```

Triggered `GRANT SELECT ON dbo.Badges TO db_reporting;` and `ALTER ROLE db_reporting ADD MEMBER [app_legacy_svc];`, and verified both statements were captured in `sys.fn_get_audit_file(N'C:\SQLAudit\*.sqlaudit', DEFAULT, DEFAULT)` (`action_id = 'G'` for Grant and `'APRL'` for Add Member to DB Role).

---

## 6. UK GDPR Controls & Dynamic Data Masking (`dbo.CustomerPII`)

| UK GDPR Obligation | Technical Control Implemented |
|---|---|
| **Article 32 — Security of processing** | `AES_256` TDE at rest, `AES_256` encrypted backups, least-privilege roles, `DBA_Lab_Audit` |
| **Article 5(1)(c) — Data minimisation** | Dynamic Data Masking on `dbo.CustomerPII` so analysts (`db_reporting`) cannot see raw NI numbers, emails, or salaries |
| **Article 17 — Right to erasure ("Right to be forgotten")** | Operational policy: row-level erasure/anonymisation in live OLTP tables, paired with documented **30-day backup retention** so encrypted backups age out naturally without destroying backup chain integrity |
| **Article 33 — 72-hour breach notification** | Synchronous `DBA_Lab_Audit` trail in `C:\SQLAudit\` identifying principal, timestamp, and exact T-SQL statement |

```sql
CREATE TABLE dbo.CustomerPII
(
    CustomerID          int IDENTITY(1,1) PRIMARY KEY,
    FullName            nvarchar(100) MASKED WITH (FUNCTION = 'partial(1, "XXXX", 1)') NOT NULL,
    EmailAddress        nvarchar(100) MASKED WITH (FUNCTION = 'email()') NOT NULL,
    NationalInsuranceNo varchar(15)   MASKED WITH (FUNCTION = 'partial(2, "-XX-XX-XX-", 1)') NOT NULL,
    SalaryGBP           decimal(10,2) MASKED WITH (FUNCTION = 'default()') NOT NULL
);
```

**Observed Output (`DBA` vs `EXECUTE AS USER = 'usr_reporting'`):**

| Viewer Context | `FullName` | `EmailAddress` | `NationalInsuranceNo` | `SalaryGBP` |
|---|---|---|---|---:|
| **`DBA (Unmasked)`** | `Amelia Clarke` | `amelia.clarke@nhs.uk` | `QQ123456C` | `48500.00` |
| **`DBA (Unmasked)`** | `Oliver Patel` | `o.patel@barclays.co.uk` | `AB987654D` | `62000.00` |
| **`db_reporting (Masked)`** | `AXXXXe` | `aXXX@XXXX.com` | `QQ-XX-XX-XX-C` | `0.00` |
| **`db_reporting (Masked)`** | `OXXXXl` | `oXXX@XXXX.com` | `AB-XX-XX-XX-D` | `0.00` |

---

## Hardening Checklist

- [x] `sa` disabled (`ALTER LOGIN [sa] DISABLE`)
- [x] `sysadmin` membership audited
- [x] `xp_cmdshell`, `Ole Automation Procedures`, `Ad Hoc Distributed Queries`, and `cross db ownership chaining` verified `0`
- [x] Permissions granted to database roles (`db_reporting`, `db_application`, `db_support`), never directly to users
- [x] No application account has `db_owner` or `sysadmin` (`DENY ALTER ON SCHEMA::dbo` verified)
- [x] Orphaned users detected and resolved via `ALTER USER ... WITH LOGIN`
- [x] `AES_256` TDE enabled on `SecVaultLab`; **`TDECert_2026.cer` and `.pvk` backed up and verified**
- [x] Native `AES_256` backup encryption verified (`SecVaultLab_Encrypted.bak`)
- [x] Server audit (`DBA_Lab_Audit`) enabled for logins, role changes, permission grants, and DDL
- [x] Dynamic Data Masking verified on UK PII columns (`NationalInsuranceNo`, `EmailAddress`, `SalaryGBP`)

---

## Interview Talking Points

- How to respond when a developer requests `sysadmin` or `db_owner` on production (offer `db_support` with `VIEW DEFINITION` + `SHOWPLAN`, or `db_application` with CRUD)
- Why `DENY CONTROL` breaks `GRANT SELECT` (`CONTROL` implies every permission on the securable, and `DENY` overrides `GRANT`)
- What an orphaned user is, why restoring to a DR server causes SID mismatches, and how `ALTER USER ... WITH LOGIN` or `Copy-DbaLogin` fixes it
- Why UK SQL Server instances (`Latin1_General_CI_AS`) hit `Msg 468` when joining catalog views against US databases (`SQL_Latin1_General_CP1_CI_AS`), and how `COLLATE DATABASE_DEFAULT` resolves it
- Why the TDE certificate backup (`.cer` + `.pvk`) matters more than enabling TDE itself
- The difference between TDE (encrypts data/log/backup files on disk transparently), Dynamic Data Masking (masks query results for non-privileged users), and Always Encrypted (client-side encryption where even the DBA cannot read plaintext)
- How to handle a UK GDPR Right-to-Erasure request when historical backups exist (erase in live DB, never edit `.bak` files, rely on documented backup retention window and re-apply erasure log if a restore is ever required)
