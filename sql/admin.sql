drop schema if exists admin cascade;
create schema admin;
set search_path to admin,public;
--
create function new_engine(ecode text, ename text, etest text, eseparator text, vcode text, vname text, lcode text default 'sql') returns void as $$
  set constraints all deferred;
  insert into engine(engine_code,engine_name,engine_test,engine_separator_regex,engine_default_version_code) values(ecode,ename,etest,eseparator,vcode);
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

--select admin.new_engine('timescaledb','TimescaleDB',$$select installed_version from pg_available_extensions where name = 'timescaledb';$$,';','2.11','2.11');
--select admin.new_version('postgres','19','19 beta 1');
--select admin.new_version('mysql','9.7','9.7');
--update engine set engine_default_version_code='9.7' where engine_code='mysql';
--update allowed set allowed_default_fiddle_code=decode(translate('X1GSk8pZ','-_','+/'),'base64') where engine_code='duckdb' and version_code='1.4' and sample_name='';
