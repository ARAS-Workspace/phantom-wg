import { CodeSnippet } from '@carbon/react';
import SimpleTable from '@shared/components/data/SimpleTable';

// noinspection JSUnusedGlobalSymbols
export const components = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  pre: (props: any) => {
    const code = props.children;
    if (!code?.props?.children) return <pre {...props} />;

    const content = code.props.children as string;

    return (
      <CodeSnippet type="multi" hideCopyButton>
        {content}
      </CodeSnippet>
    );
  },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  code: (props: any) => <code {...props} />,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  table: (props: any) => <SimpleTable>{props.children}</SimpleTable>,
};
