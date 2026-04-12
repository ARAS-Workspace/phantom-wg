/**
 * Convert human-readable date string to ISO 8601 with Istanbul timezone.
 *
 * @param date - Format: 'DD/MM/YYYY HH:mm' (Istanbul time)
 * @returns ISO 8601 string, e.g. '1997-08-02T23:55:00+03:00'
 *
 * @example
 * toISO('02/08/1997 23:55') // '1997-08-02T23:55:00+03:00'
 * toISO('16/03/2025 00:00') // '2025-03-16T00:00:00+03:00'
 */
export function toISO(date: string): string {
  const [datePart, timePart] = date.split(' ');
  const [day, month, year] = datePart.split('/');
  const [hour, minute] = (timePart || '00:00').split(':');
  return `${year}-${month.padStart(2, '0')}-${day.padStart(2, '0')}T${hour.padStart(2, '0')}:${minute.padStart(2, '0')}:00+03:00`;
}
