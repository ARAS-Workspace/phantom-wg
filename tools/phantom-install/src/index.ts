// noinspection JSUnusedGlobalSymbols

/**
 * Phantom-WG Bootstrap Installer Worker
 *
 * Serves the install.sh script for:
 * curl -sSL https://install.phantom.tc | bash
 *
 * Copyright (c) 2025 Rıza Emre ARAS
 * Licensed under AGPL-3.0
 */

import installScript from './install.sh.txt';

export default {
	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);

		// Health check endpoint
		if (url.pathname === '/health') {
			return new Response('OK', {
				status: 200,
				headers: { 'Content-Type': 'text/plain' },
			});
		}

		// IP check endpoint - returns client's public IP
		if (url.pathname === '/ip') {
			const clientIP = request.headers.get('CF-Connecting-IP') || 'unknown';
			return new Response(clientIP, {
				status: 200,
				headers: {
					'Content-Type': 'text/plain',
					'Cache-Control': 'no-cache, no-store, must-revalidate',
				},
			});
		}

		// Serve install script for root path or /install
		if (url.pathname === '/' || url.pathname === '/install') {
			return new Response(installScript, {
				status: 200,
				headers: {
					'Content-Type': 'text/x-shellscript; charset=utf-8',
					'Content-Disposition': 'inline; filename="install.sh"',
					'Cache-Control': 'no-cache, no-store, must-revalidate',
					'X-Content-Type-Options': 'nosniff',
				},
			});
		}

		// 404 for other paths
		return new Response('Not Found', {
			status: 404,
			headers: { 'Content-Type': 'text/plain' },
		});
	},
} satisfies ExportedHandler;