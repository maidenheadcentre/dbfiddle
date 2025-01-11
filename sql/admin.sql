drop schema if exists admin cascade;
create schema admin;
set search_path to admin,public;
--
create function new_engine(ecode text, ename text, edefault text[], eseparator text, vcode text, vname text) returns void as $$
  set constraints all deferred;
  insert into engine(engine_code,engine_name,engine_default,engine_separator_regex,engine_default_version_code) values(ecode,ename,edefault,eseparator,vcode);
  insert into version(engine_code,version_code,version_name) values (ecode,vcode,vname);
  insert into allowed(engine_code,version_code) values (ecode,vcode);
$$ language sql security definer set search_path=public,admin,pg_temp;
--
create function new_version(ecode text, vcode text, vname text) returns void as $$
  insert into version(engine_code,version_code,version_name) values (ecode,vcode,vname);
  insert into allowed(engine_code,version_code) values (ecode,vcode);
$$ language sql security definer set search_path=public,admin,pg_temp;
--
revoke all on all functions in schema admin from public;

--select admin.new_engine('timescaledb','TimescaleDB',$${"select installed_version from pg_available_extensions where name = 'timescaledb';"}$$,';','2.11','2.11');
--select admin.new_version('mysql','8.4','8.4');
--update engine set engine_default_version_code='8.4' where engine_code='mysql';
