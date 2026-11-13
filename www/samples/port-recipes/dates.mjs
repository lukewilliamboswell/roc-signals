const DATE_LIMIT = 8640000000000000n;

export function formatDates({ languages, zone, instants }) {
  if (instants.length > 256) throw new RangeError("A date-formatting batch has at most 256 instants");
  const format = new Intl.DateTimeFormat(languages, { timeZone: zone, dateStyle: "medium", timeStyle: "short" });
  return instants.map((text) => {
    if (typeof text !== "string" || !/^-?(0|[1-9][0-9]{0,18})$/.test(text)) throw new Error("Expected decimal I64 milliseconds");
    const instant = BigInt(text);
    // Every integer in the Date range is exactly representable as Number.
    // Validate first, rather than rounding a large I64 before rejecting it.
    if (instant < -DATE_LIMIT || instant > DATE_LIMIT) throw new RangeError("The date is outside the browser's range");
    return format.format(Number(instant));
  });
}

export const datePorts = { "example.org/recipes/format-dates": { call: formatDates } };
