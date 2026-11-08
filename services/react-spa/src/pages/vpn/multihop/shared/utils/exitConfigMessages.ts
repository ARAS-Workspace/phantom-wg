import { translate } from '@shared/translations';
import { EXIT_CONFIG_FIELD_LABELS, type ExitConfigIssue } from './exitConfig';

/**
 * One line per issue, "<key>: <message> (<value>)", the format of the mac and
 * iOS editors; a problem of the layout names its line instead of a key.
 * Shared by the import and edit modals so both report alike.
 */
export function formatExitConfigIssues(
  issues: ExitConfigIssue[],
  t: ReturnType<typeof translate>
): string[] {
  return issues.map(({ field, problem, value, line }) => {
    const label =
      field === 'line' ? `${t.multihop.validation.line} ${line}` : EXIT_CONFIG_FIELD_LABELS[field];
    const suffix = value ? ` (${value})` : '';
    return `${label}: ${t.multihop.validation[problem]}${suffix}`;
  });
}
