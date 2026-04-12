import { CodeSnippet } from '@carbon/react';
import CodeHighlight from '@shared/components/visualization/CodeHighlight';
import SimpleTable from '@shared/components/data/SimpleTable';

// noinspection JSUnusedGlobalSymbols
export const components = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  pre: (props: any) => {
    const code = props.children;
    if (!code?.props?.children) return <pre {...props} />;

    const content = code.props.children as string;
    const lang = (code.props.className as string | undefined)
      ?.replace('language-', '')
      ?.trim();

    // Language specified → shiki syntax highlighting
    if (lang) {
      return <CodeHighlight.Lazy code={content} lang={lang} />;
    }

    // No language → plain Carbon CodeSnippet
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
