drop schema if exists robots cascade;
create schema robots;
grant usage on schema robots to lambda;
set search_path to robots;
--
create function sync() returns void as $$
  --
  update visit_daily d
  set visit_daily_count_distinct_source = (
    select count(distinct source_network)
    from visit v
    where v.engine_code=d.engine_code and v.version_code=d.version_code and v.sample_name=d.sample_name and v.visit_at>=d.visit_daily_on and v.visit_at<d.visit_daily_on+1
  )
  where visit_daily_count_distinct_source is null and visit_daily_on<current_date;
  --
  update fiddle_daily d
  set fiddle_daily_count_distinct_source = (
    select count(distinct source_network)
    from fiddle f
    where f.engine_code=d.engine_code and f.version_code=d.version_code and f.sample_name=d.sample_name and f.fiddle_at>=d.fiddle_daily_on and f.fiddle_at<d.fiddle_daily_on+1
  )
  where fiddle_daily_count_distinct_source is null and fiddle_daily_on<current_date;
  --
  analyze source;
  --
$$ language sql security definer set search_path=public,pg_temp;
