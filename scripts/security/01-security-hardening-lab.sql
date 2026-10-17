/* ============================================================================
   01-security-hardening-lab.sql
   Project 03 — Security Hardening Baseline · SQL Server DBA Lab

   PURPOSE
       Executes and verifies all six security controls in Project 03:
         1. Server-level baseline audit & disabling [sa]
         2. Least-privilege roles (db_reporting, db_application, db_support)
            with live EXECUTE AS USER verification
         3. Orphaned user simulation, detection & SID remapping
            (with COLLATE DATABASE_DEFAULT for UK Latin1_General_CI_AS instances)
         4. Transparent Data Encryption (TDE), certificate backup & AES_256
            encrypted backup on SecVaultLab
         5. SQL Server Audit (Server & Schema/Permission audit trail)
         6. UK GDPR Dynamic Data Masking (DBA vs db_reporting view)
   ============================================================================ */

USE master;
GO
SET NOCOUNT ON;
SET STATISTICS XML OFF;
SET STATISTICS PROFILE OFF;
GO

PRINT '========================================================================';
PRINT 'PROJECT 03 — SECURITY HARDENING BASELINE LAB';
PRINT '========================================================================';

EXEC sys.xp_create_subdir N'C:\SQLBackup\Certs';
EXEC sys.xp_create_subdir N'C:\SQLAudit';
GO

/* ----------------------------------------------------------------------------
   1. SERVER-LEVEL BASELINE AUDIT & HARDENING
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 1. SERVER-LEVEL SECURITY BASELINE ===';

EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

SELECT
    name,
    CAST(value AS int)        AS configured_value,
    CAST(value_in_use AS int) AS running_value,
    CASE
        WHEN name IN ('xp_cmdshell', 'Ole Automation Procedures', 'Ad Hoc Distributed Queries', 'cross db ownership chaining')
             AND value_in_use = 0 THEN 'PASS (Disabled)'
        WHEN name = 'remote admin connections' THEN 'INFO (DAC)'
        ELSE 'REVIEW'
    END AS security_status
FROM sys.configurations
WHERE name IN (
    N'xp_cmdshell',
    N'Ole Automation Procedures',
    N'Ad Hoc Distributed Queries',
    N'cross db ownership chaining',
    N'remote admin connections'
)
ORDER BY name;

IF EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'sa' AND is_disabled = 0)
BEGIN
    ALTER LOGIN [sa] DISABLE;
    PRINT 'Action: Disabled [sa] login.';
END
ELSE
BEGIN
    PRINT 'Info: [sa] login is already disabled.';
END

SELECT
    sp.name        AS principal_name,
    sp.type_desc   AS principal_type,
    sp.is_disabled,
    IS_SRVROLEMEMBER('sysadmin', sp.name) AS is_sysadmin
FROM sys.server_principals sp
WHERE sp.name = N'sa'
   OR IS_SRVROLEMEMBER('sysadmin', sp.name) = 1
ORDER BY sp.type_desc, sp.name;
GO

/* ----------------------------------------------------------------------------
   2. LEAST-PRIVILEGE ROLE DESIGN & IMPERSONATION TESTS (StackOverflow2010)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 2. LEAST-PRIVILEGE ROLES & ACCESS TESTS ===';

USE StackOverflow2010;
GO

IF DATABASE_PRINCIPAL_ID(N'usr_reporting') IS NOT NULL DROP USER usr_reporting;
IF DATABASE_PRINCIPAL_ID(N'usr_application') IS NOT NULL DROP USER usr_application;
IF DATABASE_PRINCIPAL_ID(N'usr_support') IS NOT NULL DROP USER usr_support;
IF DATABASE_PRINCIPAL_ID(N'db_reporting') IS NOT NULL DROP ROLE db_reporting;
IF DATABASE_PRINCIPAL_ID(N'db_application') IS NOT NULL DROP ROLE db_application;
IF DATABASE_PRINCIPAL_ID(N'db_support') IS NOT NULL DROP ROLE db_support;
GO

CREATE ROLE db_reporting;
GRANT SELECT ON SCHEMA::dbo TO db_reporting;

-- Note: DENY ALTER only (never DENY CONTROL, because CONTROL is an umbrella
-- permission that implies SELECT/INSERT/UPDATE/DELETE and would block all CRUD!)
CREATE ROLE db_application;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO db_application;
DENY ALTER ON SCHEMA::dbo TO db_application;

CREATE ROLE db_support;
GRANT SELECT ON SCHEMA::dbo TO db_support;
GRANT VIEW DEFINITION ON SCHEMA::dbo TO db_support;

CREATE USER usr_reporting   WITHOUT LOGIN;
CREATE USER usr_application WITHOUT LOGIN;
CREATE USER usr_support     WITHOUT LOGIN;

ALTER ROLE db_reporting   ADD MEMBER usr_reporting;
ALTER ROLE db_application ADD MEMBER usr_application;
ALTER ROLE db_support     ADD MEMBER usr_support;
GO

EXECUTE AS USER = N'usr_reporting';
BEGIN TRY
    DECLARE @cnt int;
    SELECT @cnt = COUNT(*) FROM dbo.Users WHERE Id = 1;
    PRINT 'PASS [db_reporting]: SELECT succeeded (rows=' + CAST(@cnt AS varchar(10)) + ').';
    UPDATE dbo.Users SET Reputation = Reputation + 1 WHERE Id = 1;
    PRINT 'FAIL [db_reporting]: UPDATE should not have succeeded!';
END TRY
BEGIN CATCH
    PRINT 'PASS [db_reporting]: UPDATE blocked -> Msg ' + CAST(ERROR_NUMBER() AS varchar(10)) + ': ' + ERROR_MESSAGE();
END CATCH
REVERT;

EXECUTE AS USER = N'usr_application';
BEGIN TRY
    UPDATE dbo.Users SET LastAccessDate = LastAccessDate WHERE Id = 1;
    PRINT 'PASS [db_application]: UPDATE succeeded.';
    EXEC(N'ALTER TABLE dbo.Users ADD UnauthorizedCol int NULL;');
    PRINT 'FAIL [db_application]: ALTER TABLE should not have succeeded!';
END TRY
BEGIN CATCH
    PRINT 'PASS [db_application]: ALTER TABLE blocked -> Msg ' + CAST(ERROR_NUMBER() AS varchar(10)) + ': ' + ERROR_MESSAGE();
END CATCH
REVERT;

EXECUTE AS USER = N'usr_support';
BEGIN TRY
    DECLARE @defLen int = LEN(OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_GetBadgesByName')));
    PRINT 'PASS [db_support]: VIEW DEFINITION succeeded (proc length=' + COALESCE(CAST(@defLen AS varchar(10)), 'N/A') + ').';
    DELETE FROM dbo.Users WHERE Id = -999999;
    PRINT 'FAIL [db_support]: DELETE should not have succeeded!';
END TRY
BEGIN CATCH
    PRINT 'PASS [db_support]: DELETE blocked -> Msg ' + CAST(ERROR_NUMBER() AS varchar(10)) + ': ' + ERROR_MESSAGE();
END CATCH
REVERT;
GO

/* ----------------------------------------------------------------------------
   3. ORPHANED USER SIMULATION, DETECTION & SID REMAPPING
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 3. ORPHANED USER DETECTION & REMAPPING ===';

USE StackOverflow2010;
GO
IF DATABASE_PRINCIPAL_ID(N'app_legacy_svc') IS NOT NULL DROP USER [app_legacy_svc];
USE master;
GO
IF SUSER_ID(N'app_legacy_svc') IS NOT NULL DROP LOGIN [app_legacy_svc];
GO

CREATE LOGIN [app_legacy_svc] WITH PASSWORD = N'LabStrongPass!2026#A', CHECK_POLICY = OFF;
GO
USE StackOverflow2010;
GO
CREATE USER [app_legacy_svc] FOR LOGIN [app_legacy_svc];
GO

USE master;
GO
DROP LOGIN [app_legacy_svc];
CREATE LOGIN [app_legacy_svc] WITH PASSWORD = N'LabStrongPass!2026#B', CHECK_POLICY = OFF;
GO

USE StackOverflow2010;
GO
SELECT
    dp.name AS orphaned_db_user,
    dp.type_desc,
    dp.sid  AS db_user_sid,
    SUSER_SID(dp.name) AS server_login_sid,
    'ORPHANED (SID mismatch)' AS status_before_fix
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE sp.sid IS NULL
  AND dp.type IN ('S', 'U', 'G')
  AND dp.authentication_type_desc <> 'NONE'
  AND dp.principal_id > 4;

ALTER USER [app_legacy_svc] WITH LOGIN = [app_legacy_svc];
PRINT 'Action: Executed ALTER USER [app_legacy_svc] WITH LOGIN = [app_legacy_svc].';

-- Note: COLLATE DATABASE_DEFAULT resolves the collation difference between a UK instance
-- (Latin1_General_CI_AS) and US-built StackOverflow2010 (SQL_Latin1_General_CP1_CI_AS)
SELECT
    dp.name AS remapped_db_user,
    dp.sid  AS db_user_sid,
    sp.sid  AS server_login_sid,
    CASE WHEN dp.sid = sp.sid THEN 'FIXED (SIDs match)' ELSE 'STILL ORPHANED' END AS status_after_fix
FROM sys.database_principals dp
JOIN sys.server_principals sp
    ON dp.name COLLATE DATABASE_DEFAULT = sp.name COLLATE DATABASE_DEFAULT
WHERE dp.name = N'app_legacy_svc';
GO

/* ----------------------------------------------------------------------------
   4. TRANSPARENT DATA ENCRYPTION (TDE) & BACKUP ENCRYPTION (SecVaultLab)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 4. TDE & ENCRYPTED BACKUP (SecVaultLab) ===';

USE master;
GO
IF DB_ID(N'SecVaultLab') IS NOT NULL
BEGIN
    ALTER DATABASE SecVaultLab SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SecVaultLab;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'MasterKey!DbaLab#2026_Strong';
    PRINT 'Created Database Master Key in master.';
END

IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'TDECert_2026')
BEGIN
    CREATE CERTIFICATE TDECert_2026 WITH SUBJECT = N'SQL Server DBA Lab TDE Certificate 2026';
    PRINT 'Created Server Certificate TDECert_2026.';
END
GO

BEGIN TRY
    BACKUP CERTIFICATE TDECert_2026
    TO FILE = N'C:\SQLBackup\Certs\TDECert_2026.cer'
    WITH PRIVATE KEY (
        FILE = N'C:\SQLBackup\Certs\TDECert_2026.pvk',
        ENCRYPTION BY PASSWORD = N'CertBackupKey!DbaLab#2026_Strong'
    );
    PRINT 'Backed up TDECert_2026.cer and TDECert_2026.pvk to C:\SQLBackup\Certs\.';
END TRY
BEGIN CATCH
    PRINT 'Info: TDECert_2026 backup files already exist in C:\SQLBackup\Certs\.';
END CATCH
GO

CREATE DATABASE SecVaultLab;
GO
USE SecVaultLab;
GO
CREATE TABLE dbo.PaymentTokens (TokenID int IDENTITY PRIMARY KEY, CardHash char(64) NOT NULL);
INSERT dbo.PaymentTokens (CardHash) VALUES (REPLICATE('A', 64)), (REPLICATE('B', 64));

CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER CERTIFICATE TDECert_2026;
GO
ALTER DATABASE SecVaultLab SET ENCRYPTION ON;
GO

SELECT
    DB_NAME(dek.database_id) AS database_name,
    dek.encryption_state,
    CASE dek.encryption_state
        WHEN 1 THEN 'Unencrypted'
        WHEN 2 THEN 'Encryption in progress'
        WHEN 3 THEN 'ENCRYPTED'
    END AS encryption_state_desc,
    dek.key_algorithm,
    dek.key_length,
    c.name AS encryptor_cert
FROM sys.dm_database_encryption_keys dek
LEFT JOIN master.sys.certificates c ON dek.encryptor_thumbprint = c.thumbprint
WHERE dek.database_id IN (DB_ID(N'SecVaultLab'), DB_ID(N'tempdb'));
GO

BACKUP DATABASE SecVaultLab
TO DISK = N'C:\SQLBackup\FULL\SecVaultLab_Encrypted.bak'
WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = TDECert_2026),
     COMPRESSION, CHECKSUM, INIT;
GO

/* ----------------------------------------------------------------------------
   5. SQL SERVER AUDIT (Server + Database Audit Trail)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 5. SQL SERVER AUDIT ===';

USE StackOverflow2010;
GO
IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = N'DBA_Lab_DB_Audit_Spec')
BEGIN
    ALTER DATABASE AUDIT SPECIFICATION DBA_Lab_DB_Audit_Spec WITH (STATE = OFF);
    DROP DATABASE AUDIT SPECIFICATION DBA_Lab_DB_Audit_Spec;
END
USE master;
GO
IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = N'DBA_Lab_Server_Spec')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION DBA_Lab_Server_Spec WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION DBA_Lab_Server_Spec;
END
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'DBA_Lab_Audit')
BEGIN
    ALTER SERVER AUDIT DBA_Lab_Audit WITH (STATE = OFF);
    DROP SERVER AUDIT DBA_Lab_Audit;
END
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

USE StackOverflow2010;
GO
GRANT SELECT ON dbo.Badges TO db_reporting;
ALTER ROLE db_reporting ADD MEMBER [app_legacy_svc];
GO

SELECT TOP (10)
    event_time,
    action_id,
    succeeded,
    server_principal_name,
    database_name,
    object_name,
    LEFT(statement, 120) AS audited_statement
FROM sys.fn_get_audit_file(N'C:\SQLAudit\*.sqlaudit', DEFAULT, DEFAULT)
WHERE statement IS NOT NULL AND statement <> ''
ORDER BY event_time DESC;
GO

/* ----------------------------------------------------------------------------
   6. UK GDPR — DYNAMIC DATA MASKING (dbo.CustomerPII)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 6. UK GDPR — DYNAMIC DATA MASKING ===';

USE StackOverflow2010;
GO
DROP TABLE IF EXISTS dbo.CustomerPII;
GO

CREATE TABLE dbo.CustomerPII
(
    CustomerID          int IDENTITY(1,1) PRIMARY KEY,
    FullName            nvarchar(100) MASKED WITH (FUNCTION = 'partial(1, "XXXX", 1)') NOT NULL,
    EmailAddress        nvarchar(100) MASKED WITH (FUNCTION = 'email()') NOT NULL,
    NationalInsuranceNo varchar(15)   MASKED WITH (FUNCTION = 'partial(2, "-XX-XX-XX-", 1)') NOT NULL,
    SalaryGBP           decimal(10,2) MASKED WITH (FUNCTION = 'default()') NOT NULL
);

INSERT dbo.CustomerPII (FullName, EmailAddress, NationalInsuranceNo, SalaryGBP)
VALUES
    (N'Amelia Clarke', N'amelia.clarke@nhs.uk',     'QQ123456C', 48500.00),
    (N'Oliver Patel',  N'o.patel@barclays.co.uk',   'AB987654D', 62000.00);
GO

SELECT 'DBA (Unmasked)' AS viewer_role, CustomerID, FullName, EmailAddress, NationalInsuranceNo, SalaryGBP
FROM dbo.CustomerPII;

EXECUTE AS USER = N'usr_reporting';
SELECT 'db_reporting (Masked)' AS viewer_role, CustomerID, FullName, EmailAddress, NationalInsuranceNo, SalaryGBP
FROM dbo.CustomerPII;
REVERT;
GO
