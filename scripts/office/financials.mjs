const PERIOD = /^\d{4}(?:-Q[1-4])?$/;
const SOURCE = /^https?:\/\/[^\s/?#]+(?:[/?#][^\s]*)?$/i;

function ordinal(period) {
  const year = Number(period.slice(0, 4));
  return period.length === 4 ? year : year * 4 + Number(period.slice(-1)) - 1;
}

export function financials(input) {
  if (!Array.isArray(input?.series) || !input.series.length || input.series.length > 100) {
    throw new Error('Expected 1–100 financial series.');
  }
  const series = new Map();
  for (const row of input.series) {
    const { id, label, unit, points } = row;
    if (typeof id !== 'string' || !id.trim() || series.has(id) || typeof label !== 'string' || !label.trim() ||
        typeof unit !== 'string' || !unit.trim() || !Array.isArray(points) || !points.length || points.length > 100) {
      throw new Error('Each financial series needs a unique id, label, unit and 1–100 points.');
    }
    const observed = new Map();
    for (const { period, value, source = row.source ?? input.source } of points) {
      if (typeof period !== 'string' || !PERIOD.test(period) || observed.has(period) ||
          !Number.isFinite(value) || typeof source !== 'string' || !SOURCE.test(source)) {
        throw new Error(id + ': points need a unique YYYY or YYYY-Qn period, finite value and an HTTP(S) source.');
      }
      observed.set(period, { value, source });
    }
    const periods = [...observed.keys()].sort();
    if (periods[0].length !== periods.at(-1).length) throw new Error(id + ': use separate series for annual and quarterly values.');
    series.set(id, { label, unit, observed, periods });
  }

  const metric = (id) => {
    const result = series.get(id);
    if (!result) throw new Error('Unknown financial series: ' + id);
    return result;
  };
  const point = (id, period) => {
    const row = metric(id);
    const observation = row.observed.get(period);
    if (!observation) throw new Error(id + ': missing ' + period + ' in source data.');
    return { id, label: row.label, unit: row.unit, period, ...observation };
  };
  const value = (id, period) => point(id, period).value;
  const previousYear = (period) => String(Number(period.slice(0, 4)) - 1).padStart(4, '0') + period.slice(4);
  const yoy = (id, period) => {
    const current = value(id, period);
    const prior = value(id, previousYear(period));
    if (prior <= 0) throw new Error(id + ': year-over-year growth needs a positive prior-period value; show the change in original units.');
    return (current - prior) / prior * 100;
  };
  const history = (id, period) => {
    point(id, period);
    const periods = metric(id).periods.filter((item) => item <= period);
    if (periods.length < 2 || periods.some((item, i) => i > 0 && ordinal(item) !== ordinal(periods[i - 1]) + 1)) {
      throw new Error(id + ': a historical claim needs at least two consecutive periods through ' + period + '.');
    }
    return periods;
  };
  const chart = (ids, periods) => {
    if (!Array.isArray(ids) || !ids.length || new Set(ids).size !== ids.length ||
        !Array.isArray(periods) || !periods.length || new Set(periods).size !== periods.length) {
      throw new Error('A financial chart needs unique series IDs and periods.');
    }
    const unit = metric(ids[0]).unit;
    const data = ids.map((id) => {
      const row = metric(id);
      if (row.unit !== unit) throw new Error('Use separate charts for different units.');
      return { name: row.label, values: periods.map((period) => value(id, period)) };
    });
    return { categories: periods.slice(), series: data };
  };
  const verify = (claims) => {
    if (!Array.isArray(claims) || !claims.length || claims.length > 100) throw new Error('Expected 1–100 financial claims.');
    const results = claims.map(({ id, period, kind, expected, decimals = 2 }) => {
      const observation = point(id, period);
      let actual;
      let evidence = { sources: [observation.source] };
      if (kind === 'value' || kind === 'yoy') {
        if (!Number.isFinite(expected) || !Number.isInteger(decimals) || decimals < 0 || decimals > 6) {
          throw new Error('Numeric financial claims need an expected value and 0–6 decimal places.');
        }
        actual = kind === 'value' ? observation.value : yoy(id, period);
        if (kind === 'yoy') evidence.sources = [...new Set([observation.source, point(id, previousYear(period)).source])];
      } else if (kind === 'record' || kind === 'first_decline') {
        if (typeof expected !== 'boolean') throw new Error('Historical financial claims need a boolean expected result.');
        const periods = history(id, period);
        const prior = periods.slice(0, -1).map((p) => point(id, p));
        const peak = prior.reduce((highest, item) => item.value > highest.value ? item : highest);
        const firstDecline = periods.find((p, i) => i > 0 && value(id, p) < value(id, periods[i - 1]));
        actual = kind === 'record' ? observation.value > peak.value : firstDecline === period;
        evidence = { sources: [...new Set([...prior.map((item) => item.source), observation.source])], from: periods[0], through: period,
          ...(kind === 'record' ? { previousPeak: { period: peak.period, value: peak.value, source: peak.source } } : { firstDecline }) };
      } else {
        throw new Error('Unknown financial claim kind: ' + kind);
      }
      const ok = typeof actual === 'number' ? Number(actual.toFixed(decimals)) === expected : actual === expected;
      return { id, period, kind, expected, actual, ok, ...evidence };
    });
    return { ok: results.every((result) => result.ok), checked: results.length, failed: results.filter((result) => !result.ok) };
  };
  return Object.freeze({ point, value, yoy, chart, verify });
}
