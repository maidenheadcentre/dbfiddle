(function() {
  const a = document.getElementById('chart');
  const { dates, series } = JSON.parse(a.dataset.chart);
  const colors = ['#c9d7f5','#adc2ee','#8eabe7','#6f93df','#4f7bd7','#2a5fcd'];
  const newYear = (i, date) => i > 0 && date.slice(0,4) !== dates[i-1].slice(0,4);
  const chart = echarts.init(a, null, { renderer: 'svg' });
  chart.setOption({
    animation: false,
    silent: true,
    grid: { left: 0, right: 0, top: 2, bottom: 18 },
    xAxis: {
      type: 'category', data: dates, boundaryGap: false, axisLine: { show: false }, axisTick: { show: false },
      axisLabel: { color: 'grey', interval: newYear, formatter: date => date.slice(0,4) },
      splitLine: { show: true, interval: newYear, lineStyle: { color: 'silver' } },
    },
    yAxis: { type: 'value', show: false },
    series: series.map((data, i) => ({ type: 'line', stack: 'total', data, symbol: 'none', lineStyle: { width: 0 }, areaStyle: { color: colors[i], opacity: 1 } })),
  });
  new ResizeObserver(() => chart.resize()).observe(a);
})();
