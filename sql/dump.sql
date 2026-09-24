drop schema if exists dump cascade;
create schema dump;
grant usage on schema dump to lambda;
set search_path to dump;
--
create function daily() returns text as $$
  select E'engine,version,day,fiddles,fiddlesources,visits,visitsources\n' || string_agg(format(E'%s,%s,%s,%s,%s,%s,%s\n', engine_code, version_code, daily_on, fiddles, fiddlesources, visits, visitsources), '' order by engine_code, version_code, daily_on)
  from
    (
      select engine_code, version_code, daily_on, coalesce(fiddles,0) fiddles, coalesce(fiddlesources,0) fiddlesources, coalesce(visits,0) visits, coalesce(visitsources,0) visitsources
      from
        (select engine_code, version_code, fiddle_daily_on daily_on, sum(fiddle_daily_count) fiddles, sum(fiddle_daily_count_distinct_source) fiddlesources from fiddle_daily group by engine_code, version_code, fiddle_daily_on) f natural full join
        (select engine_code, version_code, visit_daily_on daily_on, sum(visit_daily_count) visits, sum(visit_daily_count_distinct_source) visitsources from visit_daily group by engine_code, version_code, visit_daily_on) v
      where daily_on < current_date
    ) z;
$$ language sql security definer set search_path=dump,public,pg_temp;
