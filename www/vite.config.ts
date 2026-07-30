import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import mdx from '@mdx-js/rollup';
import remarkGfm from 'remark-gfm';
import remarkFrontmatter from 'remark-frontmatter';
import remarkMdxFrontmatter from 'remark-mdx-frontmatter';
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
    // No compression plugin, deliberately: Cloudflare's edge compresses every
    // response at its own quality regardless of what is uploaded — measured
    // live on a sibling Pages deployment, the edge's brotli body was 12-33%
    // larger than the stored .br for the same URL, proving the sidecars are
    // never read. They were 56% of dist's file count and bought nothing.
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
