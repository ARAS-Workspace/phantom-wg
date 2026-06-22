import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import mdx from '@mdx-js/rollup';
import remarkGfm from 'remark-gfm';
import remarkFrontmatter from 'remark-frontmatter';
import remarkMdxFrontmatter from 'remark-mdx-frontmatter';
import path from 'path';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');

  const apiTarget = env.VITE_API_TARGET || 'https://localhost:8443';

  return {
    plugins: [
      mdx({
        remarkPlugins: [remarkGfm, remarkFrontmatter, remarkMdxFrontmatter],
        providerImportSource: '@mdx-js/react',
      }),
      react(),
    ],
    server: {
      port: 5173,
      open: false,
      proxy: {
        '/auth': {
          target: apiTarget,
          changeOrigin: true,
          secure: false,
        },
        '/api': {
          target: apiTarget,
          changeOrigin: true,
          secure: false,
        },
      },
    },
    resolve: {
      alias: {
        '@shared': path.resolve(__dirname, './src/shared'),
        '@pages': path.resolve(__dirname, './src/pages'),
        '~@ibm/plex-sans': path.resolve(__dirname, './node_modules/@ibm/plex-sans'),
        '~@ibm/plex-mono': path.resolve(__dirname, './node_modules/@ibm/plex-mono'),
        '~@ibm/plex-serif': path.resolve(__dirname, './node_modules/@ibm/plex-serif'),
        '~@ibm/plex': path.resolve(__dirname, './node_modules/@ibm/plex'),
      },
      extensions: ['.tsx', '.ts', '.jsx', '.js', '.mdx'],
    },
    css: {
      preprocessorOptions: {
        scss: {
          quietDeps: true,
          additionalData: `
            @use 'sass:map';
            @use 'sass:math';
          `,
        },
      },
    },
    build: {
      sourcemap: false,
      cssCodeSplit: true,
      chunkSizeWarningLimit: 1000,
      rollupOptions: {
        output: {
          chunkFileNames: 'assets/[name]-[hash].js',
          entryFileNames: 'assets/[name]-[hash].js',
          assetFileNames: 'assets/[name]-[hash].[ext]',
        },
      },
    },
  };
});
