import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import mdx from '@mdx-js/rollup';
import remarkGfm from 'remark-gfm';
import remarkFrontmatter from 'remark-frontmatter';
import remarkMdxFrontmatter from 'remark-mdx-frontmatter';
import { compression } from 'vite-plugin-compression2';
import * as path from 'path';
import * as fs from 'fs';

export default defineConfig({
  plugins: [
    mdx({
      include: /\.mdx$/,
      remarkPlugins: [
        remarkGfm,
        remarkFrontmatter,
        [remarkMdxFrontmatter, { name: 'frontmatter' }],
      ],
      providerImportSource: '@mdx-js/react',
    }) as Plugin,
    react(),
    compression({
      include: /\.(js|mjs|json|css|html|svg)$/,
      threshold: 1024,
    }),
  ],
  server: {
    port: 5173,
    open: false,
    // HTTPS with custom certificate for www.phantom.tc
    https: fs.existsSync(path.resolve(__dirname, './certs/cert.pem'))
      ? {
          cert: fs.readFileSync(path.resolve(__dirname, './certs/cert.pem')),
          key: fs.readFileSync(path.resolve(__dirname, './certs/key.pem')),
        }
      : undefined,
  },
  preview: {
    port: 5175,
    // HTTPS with custom certificate for www.phantom.tc
    https: fs.existsSync(path.resolve(__dirname, './certs/cert.pem'))
      ? {
          cert: fs.readFileSync(path.resolve(__dirname, './certs/cert.pem')),
          key: fs.readFileSync(path.resolve(__dirname, './certs/key.pem')),
        }
      : undefined,
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
  optimizeDeps: {
    exclude: ['shiki']
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
});
