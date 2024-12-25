select date_trunc('week',visit_daily_on)::date week
     , sum(visit_daily_count) total
     , sum(visit_daily_count_distinct_source) distinct_source
     , sum(visit_daily_count_distinct_source) filter (where extract(isodow from visit_daily_on) = 1) total_mon
     , sum(visit_daily_count_distinct_source) filter (where extract(isodow from visit_daily_on) = 2) total_tue
     , sum(visit_daily_count_distinct_source) filter (where extract(isodow from visit_daily_on) = 3) total_wed
     , sum(visit_daily_count_distinct_source) filter (where extract(isodow from visit_daily_on) = 4) total_thu
     , sum(visit_daily_count_distinct_source) filter (where extract(isodow from visit_daily_on) = 5) total_fri
     , sum(visit_daily_count_distinct_source) filter (where extract(isodow from visit_daily_on) = 6) total_sat
     , sum(visit_daily_count_distinct_source) filter (where extract(isodow from visit_daily_on) = 7) total_sun
from visit_daily
group by date_trunc('week',visit_daily_on)
order by 1 desc limit 53;

select visit_referer, count(1) from visit where visit_at::date = '2022-07-12' group by visit_referer order by 2 desc limit 80;

select date_trunc('week',fiddle_daily_on)::date week
     , sum(fiddle_daily_count) total
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 1) total_mon
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 2) total_tue
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 3) total_wed
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 4) total_thu
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 5) total_fri
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 6) total_sat
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 7) total_sun
from fiddle_daily
group by date_trunc('week',fiddle_daily_on)
order by 1 desc limit 53;

select date_trunc('week',fiddle_daily_on)::date week
     , sum(fiddle_daily_count) total
     , sum(fiddle_daily_count) filter (where version_code = '3.8') total_38
     , sum(fiddle_daily_count) filter (where version_code = '3.16') total_316
     , sum(fiddle_daily_count) filter (where version_code = '3.27') total_327
     , sum(fiddle_daily_count) filter (where version_code = '3.39') total_339
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 1) total_mon
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 2) total_tue
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 3) total_wed
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 4) total_thu
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 5) total_fri
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 6) total_sat
     , sum(fiddle_daily_count) filter (where extract(isodow from fiddle_daily_on) = 7) total_sun
from fiddle_daily
where engine_code = 'sqlite'
group by date_trunc('week',fiddle_daily_on)
order by 1 desc limit 53;

select * from version where engine_code = 'sqlite';
