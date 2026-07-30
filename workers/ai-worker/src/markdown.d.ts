/** The system prompt, bundled as a text module via wrangler `rules`. */

declare module '*.md' {
	const content: string;
	export default content;
}

