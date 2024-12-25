drop schema if exists test cascade;
create schema test;
grant usage on schema test to lambda;
set search_path to test;
--
create function get() returns jsonb as $$
  select to_jsonb(z)
  from (select engine_code,version_code,sample_name,engine_default
        from (select engine_code,version_code,sample_name,engine_default
                   , extract(epoch from current_timestamp-greatest(allowed_last_test_at,max))*greatest(sum/28,1) weight
              from allowed a
                  natural join engine e
                  natural join version v
                  natural join lateral (select max(fiddle_at) from fiddle f where f.engine_code=a.engine_code and f.version_code=a.version_code and f.sample_name=a.sample_name) f
                  natural left join lateral (select sum(fiddle_daily_count) from fiddle_daily f where f.engine_code=a.engine_code and f.version_code=a.version_code and f.sample_name=a.sample_name and fiddle_daily_on>current_date-28) d
              where allowed_fail_since is null and version_is_active) z
        where weight > 250000
        order by weight desc limit 1) z;
$$ language sql security definer set search_path=test,public,pg_temp;
--
create function pass(engine text, version text, sample text) returns void as $$
  select error(500,'') where exists (select * from allowed where engine_code=engine and version_code=version and sample_name=sample and allowed_fail_since is not null);
  update allowed set allowed_last_test_at=current_timestamp where engine_code=engine and version_code=version and sample_name=sample;
  insert into test(engine_code,version_code,sample_name,test_is_passed) values(engine,version,sample,true);
$$ language sql security definer set search_path=test,public,pg_temp;
--
create function fail(engine text, version text, sample text) returns void as $$
  select error(500,'') where exists (select * from allowed where engine_code=engine and version_code=version and sample_name=sample and allowed_fail_since is not null);
  update allowed set allowed_last_test_at=current_timestamp, allowed_fail_since=current_timestamp where engine_code=engine and version_code=version and sample_name=sample;
  insert into test(engine_code,version_code,sample_name,test_is_passed) values(engine,version,sample,true);
$$ language sql security definer set search_path=test,public,pg_temp;
