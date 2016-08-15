Rem
Rem $Header: rdbms/admin/catuposb.sql cmlim_bug-22178855/1 2015/12/03 20:59:35 cmlim Exp $
Rem
Rem catuposb.sql
Rem
Rem Copyright (c) 2012, 2015, Oracle and/or its affiliates. 
Rem All rights reserved.
Rem
Rem    NAME
Rem      catuposb.sql - CAT UPgrade update Oracle-Supplied Bits
Rem
Rem    DESCRIPTION
Rem      Reads external tables objxt and userxt.
Rem      Updates obj$, user$ with oracle-supplied bits as listed in external
Rem      tables.
Rem
Rem    NOTES
Rem      Add oracle-supplied bits in dictionary after upgrading a pre-12.1
Rem      db to 12c.
Rem
Rem    MODIFIED   (MM/DD/YY)
Rem    cmlim       12/03/15 - bug 22178855: gather table stats on user$ to
Rem                           speed up select in update #4
Rem    cmlim       10/08/15 - bug 21744290: rewrite sql optimally
Rem    cmlim       03/30/15 - bug 19367547: extra: remove use of upg_xt_log_dir
Rem    cmlim       04/08/13 - drop upg_xt_log_dir directory object
Rem    cmlim       03/02/13 - bug 16306200: flush shared_pool after updating
Rem                           data dict
Rem                         - mark partition indexes and table partitions as
Rem                           oracle supplied
Rem    cmlim       03/01/13 - XbranchMerge cmlim_bug-16085743 from
Rem                           st_rdbms_12.1.0.1
Rem    cdilling    12/30/12 - XbranchMerge cdilling_bug-16031506 from
Rem                           st_rdbms_12.1.0.1
Rem    cdilling    12/19/12 - set oracle supplied bit for ordsys
Rem    cmlim       11/04/12 - bug 14763826 - add oracle-supplied bits in
Rem                           dictionary
Rem    cmlim       11/04/12 - Created
Rem


set serveroutput on

Rem ************************************************************************
Rem Create external tables with oracle-supplied bit info
Rem ************************************************************************

@@catupcox.sql


Rem ************************************************************************
Rem Update USER$'s SPARE1 with oracle_supplied bit using external table
Rem userxt as reference
Rem
Rem Note: Must do users first because some of the bit markings for system
Rem internally generated objects depend on them being owned by oracle
Rem supplied users.
Rem ************************************************************************

declare
 rc           sys_refcursor;
 name         varchar2(128);   -- username
 sqlstr       varchar2(5000);  -- to build the sql stmt for execute
 rows_queried number;          -- # of rows returned in a query
 rows_updated number := 0;     -- total # of rows updated

begin

  EXECUTE IMMEDIATE 'select count(*) from sys.userxt' into rows_queried;
  dbms_output.put_line('catuposb.sql : ' || rows_queried ||
                        ' rows in userxt');

  EXECUTE IMMEDIATE
    'select count(*) from sys.user$ where bitand(spare1, 256) = 256'
    into rows_queried;
  dbms_output.put_line('catuposb.sql : before update - ' || rows_queried ||
                       ' oracle-supplied user$ rows');

  -- begin of update in user$
  BEGIN
    OPEN rc FOR select name
                from sys.userxt;

    LOOP
      FETCH rc INTO name;
      EXIT WHEN rc%NOTFOUND;
    
      sqlstr := 'update sys.user$ ' ||
                'set spare1 = spare1 + 256 ' ||
                'where bitand(spare1, 256) = 0 ' || 
                ' and name = ''' || name || '''';

      execute immediate sqlstr;

      rows_updated := rows_updated + SQL%ROWCOUNT;
    END LOOP;
    commit;
    CLOSE rc;
  END;  -- end of update

  dbms_output.put_line('catuposb.sql : ' || rows_updated ||
                       ' user$ rows updated with oracle-supplied bit');

  EXECUTE IMMEDIATE
    'select count(*) from sys.user$ where bitand(spare1, 256) = 256'
    into rows_queried;
  dbms_output.put_line('catuposb.sql : after update - ' || rows_queried ||
                       ' oracle-supplied user$ rows');

  -- bug 22178855: gather table stats on user$ after update to avoid slow
  -- select in update 4
  dbms_stats.gather_table_stats('SYS', 'USER$');

end;
/



Rem ************************************************************************
Rem Update OBJ$'s FLAGS with oracle_supplied bit using external table
Rem objxt as reference
Rem ************************************************************************


--
-- Update 1 - update of objects where subname IS null
--
declare
  rc       sys_refcursor;
  sqlstr   varchar2(5000);  -- to build the sql stmt for execute
  objid    number;          -- object id

  -- create a record of arrays to store object info
  type objRec is record
  (
    name     dbms_sql.varchar2_table,
    owner    dbms_sql.varchar2_table,
    type#    dbms_sql.number_table
  );

  -- variables associated with objRec
  o_rec         objRec;           -- obj record
  rows_queried  number;           -- # of rows returned in a query
  rows_updated  number := 0;      -- # of rows updated      

BEGIN

  EXECUTE IMMEDIATE
    'select count(*) from sys.obj$ where bitand(flags, 4194304) = 0'
    into rows_queried;
  dbms_output.put_line('catuposb.sql : before update - ' || rows_queried ||
                       ' not oracle-supplied obj$ rows');

  EXECUTE IMMEDIATE
    'select count(*) from sys.obj$ where bitand(flags, 4194304) = 4194304'
    into rows_queried;
  dbms_output.put_line('catuposb.sql : before update - ' || rows_queried ||
                       ' oracle-supplied obj$ rows');

  dbms_output.put_line(' ');

  sqlstr := 'select owner, name, "TYPE#" ' ||
            '   from sys.objxt ' ||
            '   where subname is null';

  -- select from external table objxt where subname IS null
  OPEN rc FOR sqlstr;

  -- bulk collect results into obj record of arrays
  LOOP
    FETCH rc BULK COLLECT INTO
      o_rec.owner, o_rec.name, o_rec.type#
    LIMIT 10000;

    EXIT WHEN o_rec.owner.count = 0;

    -- update obj$ using the data from objxt
    forall i in 1 .. o_rec.owner.count
      update sys.obj$
        set flags = flags + 4194304
        where  bitand(flags, 4194304) = 0
        and name = o_rec.name(i)
        and subname is null
        and "OWNER#" =
            ( select "USER#" from sys.user$
              where name = o_rec.owner(i) )
        and "TYPE#" = o_rec.type#(i) ;

    -- rows updated in obj$ so far
    rows_updated := rows_updated + SQL%ROWCOUNT;
    commit;
  END LOOP;
  CLOSE rc;

  dbms_output.put_line('catuposb, update 1 - rows updated ' || rows_updated);
END;  -- end of update where obj$.subname is null
/


--
-- Update 2 - update obj$ where subname is NOT null
--
declare
  rc       sys_refcursor;
  sqlstr   varchar2(5000);  -- to build the sql stmt for execute
  objid    number;          -- object id

  -- create a record of arrays to store object info
  type objRec is record
  (
    name     dbms_sql.varchar2_table,
    subname  dbms_sql.varchar2_table,
    owner    dbms_sql.varchar2_table,
    type#    dbms_sql.number_table
  );

  -- variables associated with objRec
  o_rec         objRec;           -- obj record
  rows_updated  number := 0;      -- # of rows updated      

begin

  sqlstr := 'select owner, name, subname, "TYPE#" ' ||
            '   from sys.objxt ' ||
            '   where subname is not null';

  -- select from external table objxt where subname IS NOT null
  OPEN rc FOR sqlstr;

  -- bulk collect results into obj record of arrays
  LOOP
    FETCH rc BULK COLLECT INTO
      o_rec.owner, o_rec.name, o_rec.subname, o_rec.type#
    LIMIT 10000;

    EXIT WHEN o_rec.owner.count = 0;

    -- update obj$ using the data from objxt
    forall i in 1 .. o_rec.owner.count
      update sys.obj$
        set flags = flags + 4194304
        where  bitand(flags, 4194304) = 0
          and name = o_rec.name(i)
          and subname is not null
          and subname = o_rec.subname(i)
          and "OWNER#" =
              ( select "USER#" from sys.user$
                where name = o_rec.owner(i) )
          and "TYPE#" = o_rec.type#(i) ;

    -- rows updated in obj$ so far
    rows_updated := rows_updated + SQL%ROWCOUNT;
    commit;
  END LOOP;
  CLOSE rc;

  dbms_output.put_line('catuposb, update 2 - rows updated ' || rows_updated);
END;  -- end of update where obj$.subname is not null
/


--
-- Update 3 - update obj$ where owner is ordsys and type# is 13
--
declare
  type ctyp is ref cursor;
  rowid_cur ctyp;
  rowid_tab dbms_sql.urowid_table;
  sqlstr   varchar2(5000);  -- to build the sql stmt for execute
  objid    number;          -- object id

  -- create a record of arrays to store object info
  type objRec is record
  (
    name     dbms_sql.varchar2_table,
    type#    dbms_sql.number_table
  );

  -- variables associated with objRec
  rows_updated  number := 0;      -- # of rows updated      

BEGIN

  OPEN rowid_cur FOR select rowid
                     from sys.obj$
                     where
                       bitand(flags, 4194304) = 0
                       and subname is null
                       and "OWNER#" = 
                         (select "USER#" from sys.user$
                          where name = 'ORDSYS')
                       and "TYPE#" = 13;

  -- bulk collect results into obj record of arrays
  LOOP
    FETCH rowid_cur BULK COLLECT INTO rowid_tab limit 10000;
    EXIT WHEN rowid_tab.count = 0;

    --
    -- begin of update in obj$ where owner is ordsys and type# is 13
    -- 
    -- This specific update is needed because these "orphan" types in 
    -- ORDSYS are created solely in response to the registration of
    -- ORACLE-SUPPLIED XML schemas (not user schemas) and so they are
    -- Oracle-supplied themselves. 
    -- 
    forall i in 1 .. rowid_tab.count
    execute immediate
      'update sys.obj$ ' ||
       'set flags = flags + 4194304 ' ||
       'where  bitand(flags, 4194304) = 0 ' ||
       'and rowid = :1' using rowid_tab(i);

    -- rows updated in obj$ so far
    rows_updated := rows_updated + SQL%ROWCOUNT;
    commit;
  END LOOP;
  CLOSE rowid_cur;

  dbms_output.put_line('catuposb, update 3 - rows updated ' || rows_updated);
END;  -- end of update of ORDSYS objects
/


  --
  -- Update 4 - update obj$ for these system internal generated objects:
  -- SYS_IOT_OVER_%, SYS_IOT_TOP_%, SYS_LOB%, SYS_IL%, SYS_YOID%
  --
declare
  rc            sys_refcursor;
  sqlstr        varchar2(5000);  -- to build the sql stmt for execute
  objid         number;          -- object id
  rows_updated  number := 0;     -- # of rows updated      

  type objRec is record
  (
    sys_il        dbms_sql.varchar2_table,
    sys_iot_over  dbms_sql.varchar2_table,
    sys_iot_top   dbms_sql.varchar2_table,
    sys_lob       dbms_sql.varchar2_table,
    sys_yoid      dbms_sql.varchar2_table,
    owner#        dbms_sql.number_table,
    obj#          dbms_sql.number_table
  );
  o_rec objRec;


begin  

  -- for these system internally generated objects that are (1) not marked
  -- oracle supplied and (2) are owned by oracle supplied users, then
  -- parse their system generated names for base obj#s 
  OPEN rc FOR select 'SYS_IL%' || obj# || '%', 
                     'SYS_IOT_OVER%' || obj# || '%',
                     'SYS_IOT_TOP%' || obj# || '%',
                     'SYS_LOB%' || obj# || '%',
                     'SYS_YOID%' || obj# || '%',
                     o.owner#,
                     o.obj#
              from sys.obj$ o, sys.user$ u
              where bitand(o.flags, 4194304) = 4194304
                and o.owner# = u.user# and bitand(u.spare1, 256) = 256
                and obj# in
                  (select unique(regexp_substr(o.name, '([[:digit:]]+)'))
                   from sys.obj$ o, sys.user$ u
                   where
                     (o.name like 'SYS\_IL%' ESCAPE '\'
                      or o.name like 'SYS\_IOT\_OVER_%' ESCAPE '\'
                      or o.name like 'SYS\_IOT\_TOP\_%' ESCAPE '\'
                      or o.name like 'SYS\_LOB%' ESCAPE '\'
                      or o.name like 'SYS\_YOID%' ESCAPE '\')
                     and bitand(o.flags, 4194304) = 0
                     and o.owner# = u.user#
                     and bitand(u.spare1, 256) = 256);
 
  LOOP
    FETCH rc BULK COLLECT INTO o_rec LIMIT 10000;
    EXIT WHEN o_rec.sys_il.count = 0;
  
    -- mark system internally generated objs with oracle supplied bit
    -- if base object is oracle supplied and system internal obj had not
    -- been marked yet
    forall i in 1 .. o_rec.sys_il.count
      execute immediate
        'update sys.obj$ set flags = flags + 4194304 ' ||
        'where ' ||  
        ' (name like :1 ' || 
        '  or name like :2 ' || 
        '  or name like :3 ' || 
        '  or name like :4 ' || 
        '  or name like :5) ' || 
        ' and owner# = :6 ' ||
        ' and bitand(flags, 4194304) = 0 ' ||
        ' and regexp_substr(name, ''([[:digit:]]+)'') = :7 '
         using 
         o_rec.sys_il(i),
         o_rec.sys_iot_over(i),
         o_rec.sys_iot_top(i),
         o_rec.sys_lob(i),
         o_rec.sys_yoid(i),
         o_rec.owner#(i),
         o_rec.obj#(i);

    -- rows updated in obj$ so far
     rows_updated := rows_updated + SQL%ROWCOUNT;
    commit;
  END LOOP;
  CLOSE rc;

  dbms_output.put_line('catuposb, update 4 - rows updated ' || rows_updated);
END;  -- end of update for system internally generated objs
/


--
-- Update 5 - begin of update in obj$ for these system internal generated objects:
-- SYS_C% (like SYS_C00698) and SYS_FK%
--
declare
  type ctyp is ref cursor;
  oc ctyp;
  objid_tab dbms_sql.number_table;
  rows_updated  number := 0;      -- # of rows updated      

  --
  -- begin of update in obj$ for these system internal generated objects:
  -- SYS_C% (like SYS_C00698) and SYS_FK%
  --
BEGIN
  -- find obj#s for SYS_C% and SYS_FK% where (1) the index had not been
  -- marked as oracle supplied yet and (2) where table is oracle supplied
  -- and (3) index owner is oracle supplied
  --
  -- note: iu for index-user, io for index-obj, ibo for index's-base-obj
  OPEN oc FOR select io.obj#
              from sys.ind$ i, sys.user$ iu,
                   sys.obj$ io, sys.obj$ ibo
              where (io.name like 'SYS_C%' or io.name like 'SYS_FK%')
                    and io.type# = 1
                    and io.obj# = i.obj# 
                    and i.bo# = ibo.obj#
                    and bitand(io.flags, 4194304) = 0
                    and bitand(ibo.flags, 4194304) = 4194304
                    and io.owner# = iu.user#
                    and bitand(iu.spare1, 256) = 256;
 
  LOOP
    FETCH oc BULK COLLECT INTO objid_tab LIMIT 10000;
    EXIT WHEN objid_tab.count = 0;

    -- mark SYS_C% and SYS_FK% objs with oracle supplied bit if objects
    -- had not been marked yet
                                                
    forall i in 1 .. objid_tab.count
    EXECUTE IMMEDIATE
      'update sys.obj$ set flags = flags + 4194304 ' ||
      'where obj# = :1 and bitand(flags, 4194304) = 0'
      using objid_tab(i);

    -- rows updated in obj$ so far
    rows_updated := rows_updated + SQL%ROWCOUNT;
    commit;
  END LOOP;
  CLOSE oc;

  dbms_output.put_line('catuposb, update 5 - rows updated ' || rows_updated);
END;  -- end of update for system internally generated objs
/


--
-- Update 6 - begin of update in obj$ for PARTITION TABLES
--
-- (1) will mark unmarked partition table (type# 19) if base table (type# 2)
--     had already been marked as oracle supplied
-- USERNAME  OBJECTNAME                     TYPE# SUBNAME
-- SYS       WRH$_ACTIVE_SESSION_HISTORY    19    WRH$_ACTIVE_1060409768_76 
-- SYS       WRH$_ACTIVE_SESSION_HISTORY    2
--
-- (2) will mark unmarked partition index (type# 20) if base index (type# 1)
--     had been marked as oracle supplied
-- USERNAME  OBJECTNAME                     TYPE# SUBNAME
-- SYS       WRH$_REPORTS_DETAILS_IDX01     20    SYS_P222
-- SYS       WRH$_REPORTS_DETAILS_IDX01     1
--
declare
  type ctyp is ref cursor;
  oc ctyp;
  objid_tab dbms_sql.number_table;
  rows_updated  number := 0;      -- # of rows updated      
  rows_queried  number := 0;      -- # of rows queried      

BEGIN
  OPEN oc FOR select p.obj#
              from sys.obj$ p, sys.obj$ t
              where
                p.type# in (19, 20) and p.subname is not null
                   and bitand(p.flags, 4194304)=0
                and p.name = t.name and p.owner# = t.owner#
                and t.type# in (2, 1) and t.subname is null
                   and bitand(t.flags, 4194304)=4194304;

  LOOP
    FETCH oc BULK COLLECT INTO objid_tab limit 10000;
    EXIT WHEN objid_tab.count = 0;
  
    forall i in 1 .. objid_tab.count
    EXECUTE IMMEDIATE
      'update sys.obj$ set flags = flags + 4194304 ' ||
      'where obj# = :1'
      using objid_tab(i);

    rows_updated := rows_updated + SQL%ROWCOUNT;
    commit;
  END LOOP;
  CLOSE oc;

  dbms_output.put_line('catuposb, update 6 - rows updated ' || rows_updated);


  --
  -- end of updating oracle supplied bit in obj$
  -- now determine # of rows that had been updated
  --

  EXECUTE IMMEDIATE
    'select count(*) from sys.obj$ where bitand(flags, 4194304) = 0'
    into rows_queried;
  dbms_output.put_line('catuposb.sql : after update - ' || rows_queried ||
                       ' not oracle-supplied obj$ rows');

  EXECUTE IMMEDIATE
    'select count(*) from sys.obj$ where bitand(flags, 4194304) = 4194304'
    into rows_queried;
  dbms_output.put_line('catuposb.sql : after update - ' || rows_queried ||
                       ' oracle-supplied obj$ rows');

  
END;  -- end of update for system internally generated objs
/


alter system flush shared_pool;

Rem ************************************************************************
Rem drop external tables and associated directory objects
Rem ************************************************************************

 drop table sys.objxt;
 drop table sys.userxt;
 drop directory upg_xt_dir;

set serveroutput off
