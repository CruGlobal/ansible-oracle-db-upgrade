Rem
Rem Copyright (c) 2013,2014 Oracle. All rights reserved.
Rem
Rem    NAME
Rem     upg_tzv_check.sql - time zone update check script for 11gR2 (and higher)
Rem  Version 1.9
Rem     published in note 1585343.1 Scripts to automatically update the RDBMS DST (timezone) version in an 11gR2 or 12cR1 database .
Rem
Rem    NOTES
Rem      * This script must be run using SQL*PLUS from the database home.
Rem      * This script must be connected AS SYSDBA to run.
Rem      * The database need to be 11.2.0.1 or higher.
Rem      * The database will NOT be restarted .
Rem      * NO downtime is needed for this script.
Rem   	 * This script takes no arguments.
Rem      * This script WILL exit SQL*PLUS when an error is detected
Rem      * The dba_recyclebin WILL be purged.
Rem      * This script will check for all known issues at time of last update.
Rem      * An UPG_TZV table will be created.
Rem      * TZ_VERSION in Registry$database will be updated with current version.
Rem      * The upg_tzv_apply.sql script depends on this script.
Rem      * The script will write a line into the alert.log when ending succesfully.
Rem
Rem    DESCRIPTION
Rem      This script prepares a database to update the database to the highest
Rem      installed timezone definitions using the upg_tzv_apply.sql script.
Rem
Rem  MODIFIED (MM/DD/YY)
Rem     gvermeir  08/22/14 - updated to handle CDB/PDB (Multitenant) DST updates
Rem     gvermeir  07/10/14 - changed 1882 in DST$ERROR_TABLE from error to warning
Rem     gvermeir  05/23/14 - changed detection of Bug 14732853 to avoid using DBA_TSTZ_TAB_COLS
Rem     gvermeir  03/17/14 - logging of time makes more sense in minutes
Rem     gvermeir  03/04/14 - known bug detection is now faster on some dbs
Rem     gvermeir  02/20/14 - added logging to alert.log
Rem     gvermeir  12/23/13 - minor changes on error handling
Rem     gvermeir  09/20/13 - enhanced error checking and handling
Rem     gvermeir  06/12/13 - enhanced storing of found result
Rem     gvermeir  06/07/13 - corrected check for bug 14732853
Rem     gvermeir  05/16/13 - Additional check added/typos fixed
Rem     gvermeir  05/13/13 - Initial internal release
Rem     gvermeir  04/23/13 - created
Rem
SET TERMOUT OFF
SET SERVEROUTPUT ON
SET FEEDBACK OFF
-- Get time
VARIABLE V_TIME NUMBER 
EXEC :V_TIME := DBMS_UTILITY.GET_TIME
-- Set client_info so one can use:
-- select .... from V$SESSION where CLIENT_INFO = 'upg_tzv';
EXEC DBMS_APPLICATION_INFO.SET_CLIENT_INFO('upg_tzv');
whenever SQLERROR EXIT
-- Alter session to avoid performance issues
ALTER session SET nls_sort='BINARY';
-- Faster selects on ALL_TSTZ_TAB_COLS
ALTER session SET "_with_subquery"='MATERIALIZE';
SET TERMOUT ON
-- Check if user is sys
DECLARE
  V_CHECKVAR1 VARCHAR2(10 CHAR);
BEGIN
  EXECUTE immediate 'select substr(SYS_CONTEXT(''USERENV'',''CURRENT_USER''),1,10) from dual' INTO V_CHECKVAR1 ;
  IF V_CHECKVAR1 = TO_CHAR('SYS') THEN
    NULL;
  ELSE
    DBMS_OUTPUT.PUT_LINE('ERROR: Current connection is not a sysdba connection!');
    RAISE_APPLICATION_ERROR(-20001,'Stopping script - see previous message .....');
  END IF;
END;
/
-- Give some info
EXEC DBMS_OUTPUT.PUT_LINE('INFO: Starting with RDBMS DST update preparation.' );
EXEC DBMS_OUTPUT.PUT_LINE('INFO: NO actual RDBMS DST update will be done by this script.' );
EXEC DBMS_OUTPUT.PUT_LINE('INFO: If an ERROR occurs the script will EXIT sqlplus.' );
EXEC DBMS_OUTPUT.PUT_LINE('INFO: Doing checks for known issues ...' );
-- All pre-checks
DECLARE
  V_DBVERSION VARCHAR2(8 CHAR);
  V_ISPDB     VARCHAR2(3 CHAR);
  V_OLDDBTZV  NUMBER;
  V_CHECKNUM1 NUMBER;
  V_CHECKNUM2 NUMBER;
  V_CHECKVAR1 VARCHAR2(10 CHAR);
  V_CHECKVAR2 VARCHAR2(10 CHAR);
BEGIN
  -- Making sure that only Release 11gR2 and up uses this script
  BEGIN
    BEGIN
      EXECUTE immediate 'SELECT substr(VERSION,1,8)from V$INSTANCE' INTO V_DBVERSION ;
    EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: VERSION from V$INSTANCE gives no rows.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do an manual update and checks as documented in ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c.');
      RAISE_APPLICATION_ERROR(-20010,'Stopping script - see previous message .....');
    END;
    IF SUBSTR(V_DBVERSION,1,6) IN ('8.1.7.','8.1.6.','8.1.5.','8.0.6.','8.0.5.','8.0.4.','9.0.1.','9.2.0.','10.1.0','10.2.0','11.1.0') THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: This script cannot be used in Release ' || V_DBVERSION);
      DBMS_OUTPUT.PUT_LINE('ERROR: Please see note 412160.1 for the relevant note ');
      DBMS_OUTPUT.PUT_LINE('ERROR: when applying a DST patch to a database. ');
      DBMS_OUTPUT.PUT_LINE('ERROR: When upgrading to 11.2 or higher you need to run ' );
      DBMS_OUTPUT.PUT_LINE('ERROR: the upg_tzv_check.sql and upg_tzv_apply(_pdb).sql scripts ' );
      DBMS_OUTPUT.PUT_LINE('ERROR: AFTER the RDBMS version upgrade. ' );
      RAISE_APPLICATION_ERROR(-20011,'Stopping script - see previous message .....');
    ELSE
      DBMS_OUTPUT.PUT_LINE('INFO: Database version is '|| V_DBVERSION || ' .');
    END IF;
  END;
  -- check if db is READ WRITE 
  BEGIN
    EXECUTE immediate 'select OPEN_MODE from V$DATABASE' INTO V_CHECKVAR2;
    IF V_CHECKVAR2 != TO_CHAR('READ WRITE') THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: This database is in ' || V_CHECKVAR2 ||' mode.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Please restart the database READ WRITE mode ');
      RAISE_APPLICATION_ERROR(-20021,'Stopping script - see previous message .....');
    END IF;
  END;
  -- check if 12c database is Multitenant or not and warn when updating CDB$ROOT for open PDBs
  V_CHECKVAR1 := SUBSTR(V_DBVERSION,1,4);
  BEGIN
    IF V_CHECKVAR1 IN ('12.1','12.2') THEN
      EXECUTE immediate 'select CDB from V$DATABASE' INTO V_CHECKVAR2;
      IF V_CHECKVAR2 = TO_CHAR('NO') THEN
        V_ISPDB     := TO_CHAR('NO');
      ELSE
        DBMS_OUTPUT.PUT_LINE('INFO: This database is a Multitenant database.');
        EXECUTE immediate 'select SYS_CONTEXT(''USERENV'',''CON_NAME'') from dual' INTO V_CHECKVAR1;
        IF V_CHECKVAR1 = TO_CHAR('CDB$ROOT') THEN
		  DBMS_OUTPUT.PUT_LINE('INFO: Current container is CDB$ROOT .');		
		  DBMS_OUTPUT.PUT_LINE('INFO: Updating the RDBMS DST version of the CDB / CDB$ROOT database ');
		  DBMS_OUTPUT.PUT_LINE('INFO: will NOT update the RDBMS DST version of PDB databases in this CDB.');		
          V_ISPDB := TO_CHAR('NO');
		  EXECUTE immediate 'select count(*) from V$PDBS where NAME != TO_CHAR(''PDB$SEED'') and OPEN_MODE != TO_CHAR(''MOUNTED'')' INTO V_CHECKNUM1;
			IF V_CHECKNUM1 = TO_NUMBER('0') THEN
			  DBMS_OUTPUT.PUT_LINE('INFO: There are no open PDBs .');
			ELSE
			  DBMS_OUTPUT.PUT_LINE('WARNING: There are '|| V_CHECKNUM1 ||' open PDBs .');
			  DBMS_OUTPUT.PUT_LINE('WARNING: They will be closed when running upg_tzv_apply.sql .');
			END IF;
        ELSE
		  DBMS_OUTPUT.PUT_LINE('INFO: This database is a PDB.');
		  DBMS_OUTPUT.PUT_LINE('INFO: Current PDB is '||V_CHECKVAR1||' .');	
          V_ISPDB := TO_CHAR('YES');		
        END IF;
      END IF;
	ELSE
	  V_ISPDB := TO_CHAR('NO');
    END IF;
  END;
  -- Check if DST_UPGRADE_STATE is NONE
  BEGIN
    BEGIN
      EXECUTE immediate 'select substr(PROPERTY_VALUE, 1, 10) from DATABASE_PROPERTIES where PROPERTY_NAME = ''DST_UPGRADE_STATE''' INTO V_CHECKVAR1;
    EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_PRIMARY_TT_VERSION from DATABASE_PROPERTIES gives no rows.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do an manual update and checks as documented in ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c.');
      RAISE_APPLICATION_ERROR(-20031,'Stopping script - see previous message .....');
    END;
    IF V_CHECKVAR1 = TO_CHAR('NONE') THEN
      NULL;
    ELSIF V_CHECKVAR1 = TO_CHAR('PREPARE') THEN
      DBMS_OUTPUT.PUT_LINE('WARNING: Current DST_UPGRADE_STATE is '|| V_CHECKVAR1 || ' !');
      DBMS_OUTPUT.PUT_LINE('WARNING: DST_UPGRADE_STATE in DATABASE_PROPERTIES need to be NONE ');
      DBMS_OUTPUT.PUT_LINE('WARNING: before running upg_tzv_check.sql .');
      DBMS_OUTPUT.PUT_LINE('WARNING: Trying to end PREPARE window and then continue');
      DBMS_DST.END_PREPARE;
      -- if this fails it will error out in next Check if DST_SECONDARY_TT_VERSION is zero check
    ELSIF V_CHECKVAR1 = TO_CHAR('DATAPUMP') THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: Current DST_UPGRADE_STATE is '|| V_CHECKVAR1 || ' !');
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_UPGRADE_STATE in DATABASE_PROPERTIES need to be NONE ');
      DBMS_OUTPUT.PUT_LINE('ERROR: before running upg_tzv_check.sql .');
      DBMS_OUTPUT.PUT_LINE('ERROR: wait until the datapump load is done or check ');
      DBMS_OUTPUT.PUT_LINE('ERROR: Note 336014.1 How To Cleanup Orphaned DataPump Jobs In DBA_DATAPUMP_JOBS ?');
      RAISE_APPLICATION_ERROR(-20032,'Stopping script - see previous message .....');
    ELSIF V_CHECKVAR1 = TO_CHAR('UPGRADE') THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: Current DST_UPGRADE_STATE is '|| V_CHECKVAR1 || ' !');
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_UPGRADE_STATE in DATABASE_PROPERTIES need to be NONE ');
      DBMS_OUTPUT.PUT_LINE('ERROR: before running upg_tzv_check.sql .');
      DBMS_OUTPUT.PUT_LINE('ERROR: Check if an other DBA is doing a DST upgrade .');
      DBMS_OUTPUT.PUT_LINE('ERROR: If not then do the checks as documented in point 3 ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c .');
      RAISE_APPLICATION_ERROR(-20033,'Stopping script - see previous message .....');
    ELSE
      DBMS_OUTPUT.PUT_LINE('ERROR: Current DST_UPGRADE_STATE is '|| V_CHECKVAR1 || ' !');
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_UPGRADE_STATE in DATABASE_PROPERTIES need to be NONE ');
      DBMS_OUTPUT.PUT_LINE('ERROR: before running upg_tzv_check.sql.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do the checks as documented in point 3 ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c .');
      RAISE_APPLICATION_ERROR(-20034,'Stopping script - see previous message .....');
    END IF;
  END;
  -- Check if DST_SECONDARY_TT_VERSION is zero
  BEGIN
    BEGIN
      EXECUTE immediate 'select substr(PROPERTY_VALUE, 1, 3) from DATABASE_PROPERTIES where PROPERTY_NAME = ''DST_SECONDARY_TT_VERSION''' INTO V_CHECKNUM1;
    EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_PRIMARY_TT_VERSION from DATABASE_PROPERTIES gives no rows.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do an manual update and checks as documented in ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c.');
      RAISE_APPLICATION_ERROR(-20040,'Stopping script - see previous message .....');
    END;
    IF V_CHECKNUM1 = '0' THEN
      NULL;
    ELSE
      DBMS_OUTPUT.PUT_LINE('ERROR: Current DST_SECONDARY_TT_VERSION is '|| TO_CHAR(V_CHECKNUM1) || ' !');
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_SECONDARY_TT_VERSION in DATABASE_PROPERTIES need to be 0 ');
      DBMS_OUTPUT.PUT_LINE('ERROR: before this script can be run. ');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do the checks as documented in point 3 ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c .');
      RAISE_APPLICATION_ERROR(-20041,'Stopping script - see previous message .....');
    END IF;
  END;
  -- Get current TZ version seen in v$timezone_file
  -- Check that DST_PRIMARY_TT_VERSION value matches VERSION of V$TIMEZONE_FILE
  -- If not then someone messed with the *.dat files (renamed them or made symbolic links)
  BEGIN
    BEGIN
      EXECUTE immediate 'select VERSION from V$TIMEZONE_FILE' INTO V_OLDDBTZV ;
    EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: VERSION from V$TIMEZONE_FILE gives no rows.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do an manual update and checks as documented in ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c.');
      RAISE_APPLICATION_ERROR(-20050,'Stopping script - see previous message .....');
    END;
    BEGIN
      EXECUTE immediate 'select substr(PROPERTY_VALUE, 1, 3) from DATABASE_PROPERTIES where PROPERTY_NAME = ''DST_PRIMARY_TT_VERSION''' INTO V_CHECKNUM1 ;
    EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_PRIMARY_TT_VERSION from DATABASE_PROPERTIES gives no rows.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do an manual update and checks as documented in ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c.');
      RAISE_APPLICATION_ERROR(-20051,'Stopping script - see previous message .....');
    END;
    IF V_OLDDBTZV = V_CHECKNUM1 THEN
      DBMS_OUTPUT.PUT_LINE('INFO: Database RDBMS DST version is DSTv'|| TO_CHAR(V_OLDDBTZV) || ' .');
    ELSE
      DBMS_OUTPUT.PUT_LINE('ERROR: Current Server RDBMS DST version cannot be determined.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do an manual update and checks as documented in ');
      DBMS_OUTPUT.PUT_LINE('ERROR: of note 977512.1 for 11gR2 or note 1509653.1 for 12c.');
      RAISE_APPLICATION_ERROR(-20052,'Stopping script - see previous message .....');
    END IF;
  END;
  -- REGISTRY$DATABASE cleanup of previous versions of this script
  -- Set TZ_VERSION_UPGRADE column to null if it exists
  BEGIN
    EXECUTE immediate 'update REGISTRY$DATABASE set TZ_VERSION_UPGRADE =  NULL';
	COMMIT;
  EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -904 THEN -- REGISTRY$DATABASE exists but no TZ_VERSION_UPGRADE
      NULL;
    END IF;
    IF SQLCODE = -942 THEN -- no REGISTRY$DATABASE table
      NULL;
    END IF;
  END;
  -- Set TZ_VERSION column to current DST version
  BEGIN
    EXECUTE immediate 'update REGISTRY$DATABASE set TZ_VERSION = :1' USING V_OLDDBTZV;
   COMMIT;	
  EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -904 THEN -- REGISTRY$DATABASE exists but no TZ_VERSION
      NULL;
    END IF;
    IF SQLCODE = -942 THEN -- no REGISTRY$DATABASE table
      NULL;
    END IF;
  END;
  -- Drop table used by this script
  BEGIN
    EXECUTE immediate 'drop table UPG_TZV purge';
  EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -942 THEN -- ignore error if no UPG_TZV table
      NULL;
    END IF;
  END;  
  -- Version dependent checks for known bugs
  -- V_CHECKNUM2 is used to count issues found
  V_CHECKNUM2 := TO_NUMBER('0');
  --  11.2.0.1 only bugs
  IF V_DBVERSION IN ('11.2.0.1') THEN
    -- Check if case insensitive table or column names exist
    -- They give ORA-00904: invalid identifier
    -- or ORA-01747: invalid user.table.column, table.column, or column specification.
    -- Fixed in 11.2.0.2
    BEGIN
      EXECUTE immediate 'select count (*) from DBA_TAB_COLUMNS where DATA_TYPE like ''TIMESTAMP% WITH TIME ZONE'' and ( upper(TABLE_NAME) != TABLE_NAME or upper(COLUMN_NAME) != COLUMN_NAME)' INTO V_CHECKNUM1 ;
      IF V_CHECKNUM1 = TO_NUMBER('0') THEN
        NULL;
      ELSE
        DBMS_OUTPUT.PUT_LINE('ERROR: Case insensitive table or column names exist.');
        DBMS_OUTPUT.PUT_LINE('ERROR: ORA-00904 or ORA-01747 will be seen duing DBMS_DST.');
        DBMS_OUTPUT.PUT_LINE('ERROR: See known issues section of Note 977512.1 .');
        V_CHECKNUM2 := V_CHECKNUM2 + TO_NUMBER('1');
      END IF;
    END;
  END IF;
  -- no 11.2.0.2 only bugs exist
  -- 11.2.0.1, 11.2.0.2, 11.2.0.3 only bugs
  IF V_DBVERSION IN ('11.2.0.1','11.2.0.2','11.2.0.3') THEN
    -- Check if TIMESTAMP WITH TIME ZONE data type as part of an object subtype exist
    -- They give ORA-00907: missing right parenthesis
    -- Bug 13833939 - ora-0907 when preparing for dst upgrade.
    -- Fixed in 11.2.0.4 and 12c
    BEGIN
      EXECUTE immediate 'select count (*) from DBA_TSTZ_TAB_COLS where instr(QUALIFIED_COL_NAME,''TREAT'',1,1) > 0' INTO V_CHECKNUM1 ;
      IF V_CHECKNUM1 = TO_NUMBER('0') THEN
        NULL;
      ELSE
        DBMS_OUTPUT.PUT_LINE('ERROR: TSTZ data type as part of an object subtype exist.');
        DBMS_OUTPUT.PUT_LINE('ERROR: ORA-00907 will be seen during DBMS_DST.');
        DBMS_OUTPUT.PUT_LINE('ERROR: See known issues section of Note 977512.1 ');
        DBMS_OUTPUT.PUT_LINE('ERROR: for bug 13833939 .');
        V_CHECKNUM2 := V_CHECKNUM2 + TO_NUMBER('1');
      END IF;
    END;
    -- Check if there are virtual TSTZ columns
    -- They give ORA-54017: UPDATE operation disallowed on virtual columns
    -- Bug 13436809: ORA-54017 UPDATE OPERATION DISALLOWED ON VIRTUAL COLUMNS ERROR RUNNING DBMS_DST
    -- Fixed in 11.2.0.4 and 12c
    BEGIN
      EXECUTE immediate 'select count (*) from DBA_TAB_COLS C, DBA_OBJECTS O where C.DATA_TYPE like ''%WITH TIME ZONE'' and C.VIRTUAL_COLUMN =''YES'' and O.OBJECT_TYPE = ''TABLE'' and C.OWNER = O.OWNER and C.TABLE_NAME = O.OBJECT_NAME ' INTO V_CHECKNUM1 ;
      IF V_CHECKNUM1 = TO_NUMBER('0') THEN
        NULL;
      ELSE
        DBMS_OUTPUT.PUT_LINE('ERROR: Virtual TSTZ columns exist.');
        DBMS_OUTPUT.PUT_LINE('ERROR: ORA-54017 will be seen during DBMS_DST.');
        DBMS_OUTPUT.PUT_LINE('ERROR: See known issues section of Note 977512.1 ');
        DBMS_OUTPUT.PUT_LINE('ERROR: for bug 13436809 .');
        V_CHECKNUM2 := V_CHECKNUM2 + TO_NUMBER('1');
      END IF;
    END;
  END IF;
  -- Bugs not fixed in 11gR2 or 12c at time of script creation
  -- Check if there are unused TSTZ columns
  -- They give ORA-00904: "T"."SYS_C00001_-random number here-": invalid identifier
  -- Bug 14732853 - DBMS_DST DOES NOT HANDLE UNUSED TIMESTAMP WITH TIME ZONE COLUMNS
  -- NOT Fixed yet
  BEGIN
    EXECUTE immediate 'select count (*) from dba_tab_cols c, DBA_UNUSED_COL_TABS o where c.data_type like ''%WITH TIME ZONE'' and c.owner=o.owner and c.table_name = o.table_name and c.HIDDEN_COLUMN = ''YES''' INTO V_CHECKNUM1 ;
    IF V_CHECKNUM1 = TO_NUMBER('0')THEN
      NULL;
    ELSE
      DBMS_OUTPUT.PUT_LINE('ERROR: Unused TSTZ columns exist.');
      DBMS_OUTPUT.PUT_LINE('ERROR: ORA-00904 will be seen during DBMS_DST.');
      DBMS_OUTPUT.PUT_LINE('ERROR: See the known issues section of  ');
      DBMS_OUTPUT.PUT_LINE('ERROR: note 977512.1 for 11gR2 or note 1509653.1 for 12c .');
      DBMS_OUTPUT.PUT_LINE('ERROR: for bug 14732853 .');
      V_CHECKNUM2 := V_CHECKNUM2 + TO_NUMBER('1');
    END IF;
  END;
  -- Error out if one of above problems is detected
  BEGIN
    IF V_CHECKNUM2 != TO_NUMBER('0') THEN
      RAISE_APPLICATION_ERROR(-20060,'Stopping script - see previous message .....');
    ELSE
      DBMS_OUTPUT.PUT_LINE('INFO: No known issues detected.');
    END IF;
  END;
  -- create table for script
  BEGIN
    EXECUTE immediate 'create table UPG_TZV (NEW_TZ_VERSION number, ISPDB varchar2(3 char))';
  END;
  -- insert row to indicate PDB or not
  BEGIN
    EXECUTE immediate 'insert into UPG_TZV (NEW_TZ_VERSION,ISPDB) values (NULL,:1)' USING V_ISPDB;
	COMMIT;
  END;
  -- End block
END;
/
SET TERMOUT OFF
-- Purging dba_recyclebin
purge dba_recyclebin;
-- Alter session to avoid issue in note 1407273.1
ALTER session SET "_simple_view_merging"=TRUE;
SET TERMOUT ON
SET FEEDBACK OFF
-- Say what we do next
EXEC DBMS_OUTPUT.PUT_LINE('INFO: Now detecting new RDBMS DST version.' );
-- Now find new DST value
DECLARE
  V_NEWDBTZV      NUMBER;
  V_CHECKNUM1     NUMBER;
  V_CHECKVAR1     VARCHAR2(10 CHAR);
  V_ERRCODE       NUMBER;
  V_ERRMSG        VARCHAR2(140 CHAR);
  V_NUMFAIL       NUMBER;
  NO_NEW_TIMEZONE EXCEPTION;
  PRAGMA EXCEPTION_INIT(NO_NEW_TIMEZONE, -56921);
  INVALID_TIMEZONE_FILE EXCEPTION;
  PRAGMA EXCEPTION_INIT(INVALID_TIMEZONE_FILE, -30094);
  PREPWINDOW_FAIL EXCEPTION;
  PRAGMA EXCEPTION_INIT(PREPWINDOW_FAIL, -56922);
BEGIN
  -- Using DBMS_DST.BEGIN_PREPARE to find highest installed DST version
  -- by doing DBMS_DST.BEGIN_PREPARE from 199 to 1 .
  -- It will ORA-30094: failed to find the time zone data file if no DST patch is found
  -- in that case loop further .
  -- DBMS_DST.BEGIN_PREPARE will not error out if a newer than the current DST value
  -- is detected.
  -- A lower or equal than current TZ value gives ORA-56921: invalid time zone version,
  -- in that case stop.
  FOR I IN reverse 1..199
  LOOP
    BEGIN
      V_NEWDBTZV := I;
      DBMS_DST.BEGIN_PREPARE(I);
      EXIT;
    EXCEPTION
    WHEN INVALID_TIMEZONE_FILE THEN
      NULL;
    WHEN NO_NEW_TIMEZONE THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: No newer RDBMS DST patch has been detected.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Check if a newer RDBMS DST patch is actually installed.');
	  EXECUTE immediate 'drop table UPG_TZV purge';
      RAISE_APPLICATION_ERROR(-20070,'Stopping script - see previous message .....');
    WHEN PREPWINDOW_FAIL THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: ORA-56922: Starting a prepare window failed.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Most likly the shared pool is unable to allocate additional');
      DBMS_OUTPUT.PUT_LINE('ERROR: storage during the execution of the DBMS_DST.BEGIN_PREPARE package.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Flush the shared pool or bounced the database to free up the SGA ');
      DBMS_OUTPUT.PUT_LINE('ERROR: and then run upg_tzv_check.sql again.');
	  EXECUTE immediate 'drop table UPG_TZV purge';
      RAISE_APPLICATION_ERROR(-20071,'Stopping script - see previous message .....');
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: something went wrong during DBMS_DST.BEGIN_PREPARE');
	  EXECUTE immediate 'drop table UPG_TZV purge';
      V_ERRCODE := SQLCODE;
      V_ERRMSG  := SUBSTR(SQLERRM,1,140);
      DBMS_OUTPUT.PUT_LINE('Error code ' || V_ERRCODE || ': ' || V_ERRMSG);
      RAISE_APPLICATION_ERROR(-20072,'Stopping script - see previous message .....');
    END;
  END LOOP;
  -- Here we have if all went well a V_Newdbtzv value with the highest new TZ file found
  -- But it means also a DBMS_DST.BEGIN_PREPARE is already started
  -- So that is not needed in the following steps
  BEGIN
    DBMS_OUTPUT.PUT_LINE('INFO: Newest RDBMS DST version detected is DSTv'|| TO_CHAR(V_NEWDBTZV) || ' .' );
  END;
  -- Check if DST_UPGRADE_STATE is PREPARE
  BEGIN
    EXECUTE immediate 'select substr(PROPERTY_VALUE, 1, 10) from DATABASE_PROPERTIES where PROPERTY_NAME = ''DST_UPGRADE_STATE''' INTO V_CHECKVAR1;
    IF V_CHECKVAR1 = TO_CHAR('PREPARE') THEN
      NULL;
    ELSE
      DBMS_OUTPUT.PUT_LINE('ERROR: Current DST_UPGRADE_STATE is '|| V_CHECKVAR1 || ' !');
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_UPGRADE_STATE in DATABASE_PROPERTIES need to be PREPARE');
      DBMS_OUTPUT.PUT_LINE('ERROR: after a DBMS_DST.BEGIN_PREPARE.');
      DBMS_OUTPUT.PUT_LINE('ERROR: See note 977512.1 for 11gR2 or note 1509653.1 for 12c .');
      RAISE_APPLICATION_ERROR(-20080,'Stopping script - see previous message .....');
    END IF;
  END;
  -- Update UPG_TZV with V_Newdbtzv time zone information
  BEGIN
    EXECUTE immediate 'update UPG_TZV set NEW_TZ_VERSION = :1' USING V_NEWDBTZV;
    COMMIT;	
  END;
  -- End block
END;
/
-- Say what we do next
EXEC DBMS_OUTPUT.PUT_LINE('INFO: Next step is checking all TSTZ data.');
EXEC DBMS_OUTPUT.PUT_LINE('INFO: It might take a while before any further output is seen ...');
-- Start check on data
SET TERMOUT OFF
-- Clean up used objects
TRUNCATE TABLE SYS.DST$TRIGGER_TABLE;
TRUNCATE TABLE SYS.DST$AFFECTED_TABLES;
TRUNCATE TABLE SYS.DST$ERROR_TABLE;
SET TERMOUT ON
-- Need catch here for ORA-01882: timezone region not found -> if seen run the
-- Fix1882.sql script found in Note 414590.1 using the server home sqlplus and then retry
-- If this happens DBMS_DST.END_PREPARE need be called before exiting
DECLARE
  V_NEWDBTZV       NUMBER;
  V_CHECKNUM1      NUMBER;
  V_CHECKVAR1      VARCHAR2(10 CHAR);
  V_ERRCODE        NUMBER;
  V_ERRMSG         VARCHAR2(140 CHAR);
  V_NUMFAIL        NUMBER;
  INVALID_TIMEZONE EXCEPTION;
  PRAGMA EXCEPTION_INIT(INVALID_TIMEZONE, -1882);
BEGIN
  BEGIN
    DBMS_DST.FIND_AFFECTED_TABLES (AFFECTED_TABLES => 'SYS.DST$AFFECTED_TABLES', LOG_ERRORS => true, LOG_ERRORS_TABLE => 'SYS.DST$ERROR_TABLE');
  EXCEPTION
  WHEN INVALID_TIMEZONE THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: ORA-01882 was detected during FIND_AFFECTED_TABLES.');
    DBMS_OUTPUT.PUT_LINE('ERROR: Make sure to run upg_tzv_check.sql using the database home sqlplus.');
    DBMS_OUTPUT.PUT_LINE('ERROR: If this error is seen using the database home sqlplus');
    DBMS_OUTPUT.PUT_LINE('ERROR: then run the Fix1882.sql script found in Note 414590.1 ');
    DBMS_OUTPUT.PUT_LINE('ERROR: using the server home sqlplus.');
    DBMS_OUTPUT.PUT_LINE('ERROR: And then run upg_tzv_check.sql again.');
    DBMS_OUTPUT.PUT_LINE('ERROR: If this error persists log an SR.');
	EXECUTE immediate 'drop table UPG_TZV purge';
    DBMS_DST.END_PREPARE;
    RAISE_APPLICATION_ERROR(-20090,'Stopping script - see previous message .....');
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: Something went wrong during DBMS_DST.FIND_AFFECTED_TABLES.');
	EXECUTE immediate 'drop table UPG_TZV purge';	
    DBMS_DST.END_PREPARE;
    V_ERRCODE := SQLCODE;
    V_ERRMSG  := SUBSTR(SQLERRM,1,140);
    DBMS_OUTPUT.PUT_LINE('Error code ' || V_ERRCODE || ': ' || V_ERRMSG);
    RAISE_APPLICATION_ERROR(-20091,'Stopping script - see previous message .....');
  END;
  -- If this gives count(*) > 0 then issue warning
  BEGIN
    EXECUTE immediate 'SELECT count(*) FROM SYS.DST$ERROR_TABLE where ERROR_NUMBER in (''1878'',''1883'')' INTO V_CHECKNUM1 ;
    IF V_CHECKNUM1 != TO_NUMBER('0') THEN
      DBMS_OUTPUT.PUT_LINE('WARNING: Some TSTZ data that needs adjusting is detected');
      DBMS_OUTPUT.PUT_LINE('WARNING: during FIND_AFFECTED_TABLES.');
      DBMS_OUTPUT.PUT_LINE('WARNING: This is error_on_overlap_time and error_on_nonexisting_time data.');
      DBMS_OUTPUT.PUT_LINE('WARNING: For more information see ');
      DBMS_OUTPUT.PUT_LINE('WARNING: note 977512.1 for 11gR2 or note 1509653.1 for 12c .');
      DBMS_OUTPUT.PUT_LINE('WARNING: This is a message in case you want to check this data manually.' );
      DBMS_OUTPUT.PUT_LINE('WARNING: The exact rows are in SYS.DST$ERROR_TABLE' );
      DBMS_OUTPUT.PUT_LINE('WARNING: The upg_tzv_apply.sql script will adjust this data automatically.' );
      DBMS_OUTPUT.PUT_LINE('WARNING: It will not stop the DST upgrade.' );
    END IF;
  END;
  -- If this gives count(*) > 0 then issue warning
  BEGIN
    EXECUTE immediate 'SELECT count(*) FROM SYS.DST$ERROR_TABLE where ERROR_NUMBER in (''1882'')' INTO V_CHECKNUM1 ;
    IF V_CHECKNUM1 != TO_NUMBER('0') THEN
      DBMS_OUTPUT.PUT_LINE('WARNING: Some TSTZ data that needs correcting is detected');
      DBMS_OUTPUT.PUT_LINE('WARNING: during FIND_AFFECTED_TABLES.');
      DBMS_OUTPUT.PUT_LINE('WARNING: This is 1882 type data.');
      DBMS_OUTPUT.PUT_LINE('WARNING: For more information see ');
      DBMS_OUTPUT.PUT_LINE('WARNING: note 977512.1 for 11gR2 or note 1509653.1 for 12c .');
      DBMS_OUTPUT.PUT_LINE('WARNING: This is a message in case you want to check this data manually.' );
      DBMS_OUTPUT.PUT_LINE('WARNING: The exact rows are in SYS.DST$ERROR_TABLE' );
      DBMS_OUTPUT.PUT_LINE('WARNING: The upg_tzv_apply.sql script will adjust this data automatically.' );
      DBMS_OUTPUT.PUT_LINE('WARNING: It will not stop the DST upgrade.' );
    END IF;
  END;
  -- If this gives count(*) > 0 then error - go manual
  BEGIN
    EXECUTE immediate 'SELECT count(*) FROM SYS.DST$ERROR_TABLE where ERROR_NUMBER not in (''1878'',''1883'',''1882'')' INTO V_CHECKNUM1 ;
    IF V_CHECKNUM1 != TO_NUMBER('0') THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: Some data that cannot be handled automatically ');
      DBMS_OUTPUT.PUT_LINE('ERROR: was detected during FIND_AFFECTED_TABLES.');
      DBMS_OUTPUT.PUT_LINE('ERROR: Do a manual DST update and checks as documented in ');
      DBMS_OUTPUT.PUT_LINE('ERROR: note 977512.1 for 11gR2 or note 1509653.1 for 12c .');
	  EXECUTE immediate 'drop table UPG_TZV purge';	  
      DBMS_DST.END_PREPARE;
      RAISE_APPLICATION_ERROR(-20092,'Stopping script - see previous message .....');
    END IF;
  END;
  -- End the prepare window
  DBMS_DST.END_PREPARE;
  -- Check if DST_UPGRADE_STATE is NONE
  BEGIN
    EXECUTE immediate 'select substr(PROPERTY_VALUE, 1, 10) from DATABASE_PROPERTIES where PROPERTY_NAME = ''DST_UPGRADE_STATE''' INTO V_CHECKVAR1;
    IF V_CHECKVAR1 = TO_CHAR('NONE') THEN
      NULL;
    ELSE
      DBMS_OUTPUT.PUT_LINE('ERROR: Current DST_UPGRADE_STATE is '|| V_CHECKVAR1 || ' !');
      DBMS_OUTPUT.PUT_LINE('ERROR: DST_UPGRADE_STATE in DATABASE_PROPERTIES need to be NONE ');
      DBMS_OUTPUT.PUT_LINE('ERROR: after a DBMS_DST.END_PREPARE.');
      DBMS_OUTPUT.PUT_LINE('ERROR: See note 977512.1 for 11gR2 or note 1509653.1 for 12c.');
      RAISE_APPLICATION_ERROR(-20100,'Stopping script - see previous message .....');
    END IF;
  END;
  -- End message
  BEGIN
      DBMS_OUTPUT.PUT_LINE('INFO: A newer RDBMS DST version than the one currently used is found.');
      DBMS_OUTPUT.PUT_LINE('INFO: Note that NO DST update was yet done.');
      DBMS_OUTPUT.PUT_LINE('INFO: Now run upg_tzv_apply.sql to do the actual RDBMS DST update.' );
      DBMS_OUTPUT.PUT_LINE('INFO: Note that the upg_tzv_apply.sql script will ' );
      DBMS_OUTPUT.PUT_LINE('INFO: restart the database 2 times WITHOUT any confirmation or prompt.' );
  END;
  -- Check if db is RAC, if so warn to restart RAC DB in single instance if needed
  BEGIN
    EXECUTE immediate 'select upper(VALUE) from V$SYSTEM_PARAMETER where upper(NAME)=''CLUSTER_DATABASE''' INTO V_CHECKVAR1 ;
    IF V_CHECKVAR1 = TO_CHAR('FALSE') THEN
      NULL;
    ELSE
      DBMS_OUTPUT.PUT_LINE('WARNING: This RAC database is not started in single instance mode.');
      DBMS_OUTPUT.PUT_LINE('WARNING: Set cluster_database = false and start as single instance');
      DBMS_OUTPUT.PUT_LINE('WARNING: BEFORE running upg_tzv_apply(_cbd).sql !');
      DBMS_OUTPUT.PUT_LINE('WARNING: This is REQUIRED !');
    END IF;
  END;
  -- End block
END;
/
-- get time elapsed in minutes
EXEC :V_TIME := ROUND((DBMS_UTILITY.GET_TIME - :V_TIME)/100/60)
-- uncomment to print time it took
-- EXEC DBMS_OUTPUT.PUT_LINE(' Total Minutes elapsed : '||:V_TIME)
-- write little info to alert.
DECLARE
  V_NEWDBTZV NUMBER;
BEGIN
  EXECUTE immediate 'select NEW_TZ_VERSION from UPG_TZV' INTO V_NEWDBTZV;
  DBMS_SYSTEM.KSDWRT(2,'upg_tzv_check sucessfully found newer RDBMS DSTv'|| V_NEWDBTZV ||' and took '||:V_TIME||' minutes to run.');
  -- End block
END;
/
whenever SQLERROR CONTINUE
SET FEEDBACK ON
-- End of upg_tzv_check.sql
