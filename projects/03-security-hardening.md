# Project 03 — Security Hardening Baseline

**Status:** 🔲 Planned · **Week 3** · **Est. 6 hours**

> Replace every `[FILL IN]` with your own work. Delete this block when done.

---

## Objective

Take a default SQL Server install and harden it to a documented baseline, implementing least-privilege access for three realistic role types and enabling auditing sufficient to answer "who changed what, and when?"

---

## Threat model

| Risk | Mitigation implemented |
|---|---|
| Over-privileged application accounts | Custom database roles, no `db_owner` for apps |
| Shared/orphaned logins | Login audit, orphaned user detection |
| Data exposure at rest | TDE, backup encryption |
| Data exposure in transit | Force encryption, TLS |
| No accountability for changes | SQL Server Audit on server + database level |
| Personal data over-exposure | Dynamic Data Masking, column-level permissions |

---

## Baseline audit — what a default install gets wrong

```sql
EXEC sp_Blitz @CheckSecurity = 1;
```

`[FILL IN — findings table: sa enabled? xp_cmdshell? public permissions? sysadmin count?]`

---

## 1. Server-level hardening

```sql
-- Who has sysadmin? Should be a very short list.
SELECT sp.name, sp.type_desc, sp.is_disabled, sp.create_date
FROM sys.server_role_members rm
JOIN sys.server_principals sp ON rm.member_principal_id = sp.principal_id
JOIN sys.server_principals r  ON rm.role_principal_id   = r.principal_id
WHERE r.name = 'sysadmin';

-- Rename and disable sa
ALTER LOGIN sa DISABLE;
ALTER LOGIN sa WITH NAME = [disabled_sa_account];

-- Confirm dangerous features are off
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'xp_cmdshell';       -- want 0
EXEC sp_configure 'Ole Automation Procedures';  -- want 0
EXEC sp_configure 'remote admin connections';
```

`[FILL IN — results and any changes made]`

---

## 2. Least-privilege role design

Three roles modelling real access patterns:

```sql
USE StackOverflow2010;

-- Read-only reporting
CREATE ROLE db_reporting;
GRANT SELECT ON SCHEMA::dbo TO db_reporting;

-- Application: CRUD, no DDL, no direct table access beyond need
CREATE ROLE db_application;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO db_application;
DENY ALTER, CONTROL ON SCHEMA::dbo TO db_application;

-- Support: read data + view definitions + read DMVs, no writes
CREATE ROLE db_support;
GRANT SELECT ON SCHEMA::dbo TO db_support;
GRANT VIEW DEFINITION ON SCHEMA::dbo TO db_support;
```

**Principle applied:** grant to *roles*, never to users directly. When someone leaves, you remove them from a role rather than hunting individual grants.

`[FILL IN — test each role by connecting as a member and confirming what is and isn't permitted. Screenshot the denied attempts.]`

---

## 3. Orphaned users

```sql
-- Detect
EXEC sp_change_users_login 'Report';

-- Or, modern approach
SELECT dp.name AS db_user, dp.type_desc, dp.sid
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE sp.sid IS NULL
  AND dp.type IN ('S','U','G')
  AND dp.principal_id > 4;

-- Fix
ALTER USER [username] WITH LOGIN = [loginname];
```

**Why this happens:** restoring a database to a different instance brings database users whose SIDs don't match any login on the new server. Classic interview question — and it's the reason `Copy-DbaLogin` exists in dbatools.

---

## 4. Encryption

### TDE — encryption at rest

```sql
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '[strong password]';
CREATE CERTIFICATE TDECert WITH SUBJECT = 'TDE Certificate';

-- CRITICAL: back up the certificate. Without it the backups are unrecoverable.
BACKUP CERTIFICATE TDECert
TO FILE = 'C:\SQLBackup\Certs\TDECert.cer'
WITH PRIVATE KEY (
    FILE = 'C:\SQLBackup\Certs\TDECert.pvk',
    ENCRYPTION BY PASSWORD = '[different strong password]'
);

USE StackOverflow2010;
CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256
    ENCRYPTION BY SERVER CERTIFICATE TDECert;
ALTER DATABASE StackOverflow2010 SET ENCRYPTION ON;
```

> **The mistake that ends careers:** enabling TDE without backing up the certificate. Your backups become permanently unreadable on any other server. Say this in an interview.

### Backup encryption

```sql
BACKUP DATABASE StackOverflow2010
TO DISK = 'C:\SQLBackup\SO2010_encrypted.bak'
WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = TDECert),
     COMPRESSION, CHECKSUM;
```

`[FILL IN — verify by attempting to restore on an instance without the certificate]`

---

## 5. Auditing

```sql
USE master;
CREATE SERVER AUDIT DBA_Lab_Audit
TO FILE (FILEPATH = 'C:\SQLAudit\', MAXSIZE = 100 MB, MAX_ROLLOVER_FILES = 10)
WITH (ON_FAILURE = CONTINUE);
ALTER SERVER AUDIT DBA_Lab_Audit WITH (STATE = ON);

CREATE SERVER AUDIT SPECIFICATION DBA_Lab_Server_Spec
FOR SERVER AUDIT DBA_Lab_Audit
    ADD (FAILED_LOGIN_GROUP),
    ADD (SUCCESSFUL_LOGIN_GROUP),
    ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
    ADD (SERVER_PERMISSION_CHANGE_GROUP)
WITH (STATE = ON);

-- Read it back
SELECT event_time, action_id, succeeded, server_principal_name, statement
FROM sys.fn_get_audit_file('C:\SQLAudit\*.sqlaudit', DEFAULT, DEFAULT)
ORDER BY event_time DESC;
```

`[FILL IN — trigger a failed login and a permission change, then show them in the audit output]`

---

## 6. UK data protection considerations

Relevant because UK employers — especially NHS, financial services and the public sector — will ask.

| Obligation | Technical control |
|---|---|
| **UK GDPR Art. 32** — security of processing | TDE, TLS, least privilege, audit |
| **Data minimisation** | Column-level permissions, Dynamic Data Masking |
| **Right to erasure** | Documented deletion process; note that backups retain data until they age out |
| **Breach notification (72 hrs)** | Audit trail sufficient to determine scope |
| **Non-production environments** | Masking or anonymising production data before it's copied to dev/test |

```sql
-- Dynamic Data Masking example
ALTER TABLE dbo.Users
ALTER COLUMN EmailHash ADD MASKED WITH (FUNCTION = 'email()');
```

> **The point worth making in an interview:** the *backup retention vs right-to-erasure* tension is a real operational problem with no clean technical answer — you document it, agree a retention period with the business, and can explain the trade-off. Junior candidates almost never raise this.

---

## Hardening checklist (the deliverable)

- [ ] `sa` disabled and renamed
- [ ] sysadmin membership reviewed and minimised
- [ ] `xp_cmdshell` and OLE Automation disabled
- [ ] Mixed mode only if required; Windows auth preferred
- [ ] Permissions granted via roles, never to users
- [ ] No application account has `db_owner` or `sysadmin`
- [ ] Orphaned users detected and resolved
- [ ] TDE enabled; **certificate backed up and stored separately**
- [ ] Backup encryption enabled
- [ ] Force Encryption on for connections
- [ ] Server audit enabled for logins and permission changes
- [ ] SQL Server service running under a least-privilege account
- [ ] Default port changed / firewall restricted
- [ ] Public role permissions reviewed
- [ ] Guest user disabled in user databases

---

## Interview talking points

- How you'd respond to a developer requesting sysadmin on production
- What an orphaned user is and why restores cause them
- Why the TDE certificate backup matters more than TDE itself
- The difference between TDE and Always Encrypted
- How you'd handle a subject access request touching backups
