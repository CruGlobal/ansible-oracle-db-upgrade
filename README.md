Ansible Oracle DB Upgrade Role
=========

This role will upgrade an Oracle database.  The role is is divided into 3 sections that should be run in this order:

1. `pre_upgrade.yml` (no downtime if database is in archivelog mode)
 - run 24 hrs before planned database upgrade
 - runs pre-upgrade oracle script, performs full (level 0) backup, runs fixup scripts.

2. `upgrade.yml` (Downtime is required!)
 - performs incremental (level 1) backup, enables flashback database and creates guaranteed restore point.  Runs manual database upgrade.  Takes another full backup after upgrade is complete.

3. `upgrade_final.yml` (no downtime if database is in archivelog mode)
 - run 7 days after upgrade to finalize
 - deletes guaranteed restore point before setting database compatibility parameter.  Takes full backup (level 0).

Role Variables
--------------

Expected Variables:
from playbook:
 db_name: name of database to be upgraded

Database must be defined in dict variable "database_parameters".  All items listed are required in this role.

```yaml
database_parameters:
  <db_name>:
    db_version: # 12.1.0.2, 11.2.0.4
    sga_target: 1G
    pga_aggregate_target: 1G
    redolog_size_mb: 75
    db_recovery_file_dest_size: #size of fra, 10G
    log_mode: # archivelog, noarchivelog
    is_ps: true # run steps specific to PeopleSoft databases
```

defaults/main.yml

```yaml
  pre_upgrade: false    # set to true to run pre-upgrade tasks
  upgrade: false        # set to true to upgrade database
  upgrade_final: false  # set to true to run final upgrade tasks
```

vars/main.yml

```yaml
oracle_version: version to upgrade to (12.1.0.2)
oracle_home: new oracle home
env: environment variables to set for upgraded database

oracle_version_old: current version of the database (11.2.0.4)
oracle_home_old: current oracle home
env_old:  environment variables for current database (before upgrade)
```

Example Playbook
----------------

```yaml
    - hosts: oracle
      become: true
      become_user: oracle
      vars:
        db_name: test

      roles:
        - role: db-upgrade
```

How to Rollback an Upgrade from 12c to 11g
----------------
If an issue is encountered after the upgrade, you can use the guaranteed restore point that is created in the `12c_2_upgrade.yml` playbook. **Rollback can only be done if the compatibility parameter has not been set to the new database version**.

```
[oracle@tlorad01 ~]$ srvctl stop database -d pshrupg
[oracle@tlorad01 ~]$ sqlplus / as sysdba

SQL*Plus: Release 12.1.0.2.0 Production on Tue Nov 14 10:48:35 2017

Copyright (c) 1982, 2014, Oracle.  All rights reserved.

Connected to an idle instance.

[SYS@pshrupg1]:SQL> startup mount
[SYS@pshrupg1]:SQL> flashback database to restore point before_upgrade;
Flashback complete.

[SYS@pshrupg1]:SQL> shutdown immediate
Database dismounted.
ORACLE instance shut down.
[SYS@pshrupg1]:SQL> exit

# update /etc/oratab to point to old database home
pshrupg1:/app/oracle/11.2.0.4/dbhome_1:Y    #line added by Ansible
pshrupg:/app/oracle/11.2.0.4/dbhome_1:N         # line added by Agent

[oracle@tlorad01 ~]$ . oraenv
ORACLE_SID = [pshrupg1] ? pshrupg1
The Oracle base remains unchanged with value /app/oracle

[oracle@tlorad01 ~]$ echo $ORACLE_HOME
/app/oracle/11.2.0.4/dbhome_1

[oracle@tlorad01 ~]$ sqlplus / as sysdba
[SYS@pshrupg1]:SQL> startup mount pfile='/u01/oracle/ansible_stage/12c_upgrade/pshrupg/pshrupg_pfile.ora'
[SYS@pshrupg1]:SQL> create spfile='+DATA1/pshrupg/spfilepshrupg.ora' from pfile='/u01/oracle/ansible_stage/12c_upgrade/pshrupg/pshrupg_pfile.ora';

File created.

[SYS@pshrupg1]:SQL> shutdown immediate
Database dismounted.
ORACLE instance shut down.
[SYS@pshrupg1]:SQL> startup mount
[SYS@pshrupg1]:SQL> alter database open resetlogs;
Database altered.

[SYS@pshrupg1]:SQL> shutdown immediate
Database closed.
Database dismounted.
ORACLE instance shut down.
[SYS@pshrupg1]:SQL> exit

[oracle@tlorad01 ~]$ /app/oracle/12.1.0.2/dbhome_1/bin/srvctl downgrade database -d pshrupg -oraclehome /app/oracle/11.2.0.4/dbhome_1 -targetversion 11.2.0.4.0
[oracle@tlorad01 ~]$ srvctl start database -d pshrupg
```

### Optional Tags

To skip these optional tags use `--skip-tags` when running the playbook.  For example, if you do not want to run RMAN backups before or during the upgrade you would execute these commands:

```
# Pre-Upgrade checks without backups
ansible-playbook 12c_1_pre_upgrade.yml -i <path_to_inventory> --extra-vars="hosts=<hostname>" --skip-tags="pre_upgrade_backup"

# Upgrade database, do not backup database.
ansible-playbook 12c_2_upgrade.yml -i <path_to_inventory> --extra-vars="hosts=<hostname>" --skip-tags="backup"

# Post-Upgrade tasks, do not backup database.
ansible-playbook 12c_3_upgrade_final.yml -i <path_to_inventory> --extra-vars="hosts=<hostname>" --skip-tags="final_upgrade_backup"
```

`pre_upgrade_backup` - Level 0 backup that runs during pre-upgrade checks.  If this is skipped do not run subsequent Level 1 backups.

`archivelog` - Run during pre-upgrade playbook.  Shuts down database and enables archivelog and flashback database.

`backup` - Level 1 backup that runs before database upgrade.

`flashback` - Run during upgrade playbook.  Enables Flashback database and creates a guaranteed restore point.

`final_upgrade_backup` - Level 0 backup that runs during final upgrade tasks.
