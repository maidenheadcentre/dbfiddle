drop schema if exists down cascade;
create schema down;
grant usage on schema down to lambda;
set search_path to down;
--
create function get() returns jsonb as $$
  select to_jsonb(z)
  from (select engine_code,version_code,sample_name,engine_default
             , allowed_last_test_at=allowed_fail_since is_new
             , to_char(allowed_fail_since,'HH24:MI') fail_time
             , to_char(current_timestamp,'HH24:MI') time_now
        from allowed natural join version natural join engine
        where allowed_fail_since is not null and (current_timestamp-allowed_fail_since)>'10m'::interval and version_is_active
        order by allowed_last_test_at limit 1) z;
$$ language sql security definer set search_path=down,public,pg_temp;
--
create function pass(engine text, version text, sample text) returns interval as $$
  select error(500,'') where exists (select * from allowed where engine_code=engine and version_code=version and sample_name=sample and allowed_fail_since is null);

  with i as (insert into down(engine_code,version_code,sample_name,down_start_at)
             select engine_code,version_code,sample_name,allowed_fail_since from allowed where engine_code=engine and version_code=version and sample_name=sample
             returning current_timestamp-down_start_at)
     , u as (update allowed set allowed_last_test_at=current_timestamp, allowed_fail_since=null where engine_code=engine and version_code=version and sample_name=sample)
  select * from i;

$$ language sql security definer set search_path=down,public,pg_temp;
--
create function fail(engine text, version text, sample text) returns void as $$
  select error(500,'') where exists (select * from allowed where engine_code=engine and version_code=version and sample_name=sample and allowed_fail_since is null);
  update allowed set allowed_last_test_at=current_timestamp where engine_code=engine and version_code=version and sample_name=sample;
$$ language sql security definer set search_path=down,public,pg_temp;
