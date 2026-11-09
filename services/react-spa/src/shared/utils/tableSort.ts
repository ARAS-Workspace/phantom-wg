import type { ReactNode } from 'react';
import type { translate } from '@shared/translations';

type Translations = ReturnType<typeof translate>;

interface SortHeaderArgs {
  header: ReactNode;
  isSortHeader?: boolean;
  sortDirection?: string;
}

// translateWithId of a sortable Carbon TableHeader: the text a screen reader
// reads on the header, what its next click does. The sorted column turns
// between ascending and descending, another column starts ascending. Carbon's
// own text counts an unsorted step these tables do not have, in English only.
export const sortHeaderText =
  (t: Translations) =>
  (_messageId: string, args?: SortHeaderArgs): string => {
    const next =
      args?.isSortHeader && args.sortDirection === 'ASC'
        ? t.tableSort.descending
        : t.tableSort.ascending;
    return `${args?.header}: ${next}`;
  };
