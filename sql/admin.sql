drop schema if exists admin cascade;
create schema admin;
set search_path to admin,public;
--
create function new_engine(ecode text, ename text, etest text, vcode text, vname text, lcode text default 'sql') returns void as $$
  set constraints all deferred;
  insert into engine(engine_code,engine_name,engine_test,engine_default_version_code) values(ecode,ename,etest,vcode);
  insert into version(engine_code,version_code,version_name) values (ecode,vcode,vname);
  insert into allowed(engine_code,version_code) values (ecode,vcode);
  insert into speaks(engine_code,version_code,language_code) values (ecode,vcode,lcode);
$$ language sql security definer set search_path=public,admin,pg_temp;
--
create function new_version(ecode text, vcode text, vname text, lcode text default 'sql') returns void as $$
  insert into version(engine_code,version_code,version_name) values (ecode,vcode,vname);
  insert into allowed(engine_code,version_code) values (ecode,vcode);
  insert into speaks(engine_code,version_code,language_code) values (ecode,vcode,lcode);
$$ language sql security definer set search_path=public,admin,pg_temp;
--
revoke all on all functions in schema admin from public;
