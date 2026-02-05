// noinspection JSUnresolvedReference

/**
 * ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
 * ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
 * ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
 * ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
 * ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
 * ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
 * Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
 */

// Asciinema Player initialization for MkDocs
// Asciinema Player is loaded from vendor/asciinema-player.min.js via main.html
// See tools/vendor-builder for vendor management
// noinspection JSUnresolvedVariable, JSUnresolvedFunction

/**
 * @typedef {Object} AsciinemaPlayer
 * @property {Function} create - Create player function
 */

/* global AsciinemaPlayer */

// ─── Default Configuration ──────────────────────────────────────────────────
const PLAYER_CONFIG = {
    cols: 120,
    rows: 48,
    autoPlay: false,
    preload: true,
    loop: false,
    startAt: 0,
    speed: 1.5,
    fontSize: 'small',
    poster: 'npt:0:3',
    fit: false,
    themes: {
        dark: 'solarized-dark',    // used when data-md-color-scheme="slate"
        light: 'solarized-light'   // used when data-md-color-scheme="default"
    }
};

// ─── Player Registry ────────────────────────────────────────────────────────
// Stores element → { castFile, options } for recreation on theme change
const playerRegistry = new Map();

// ─── Initialize Phantom modules namespace ───────────────────────────────────
window.PhantomModules = window.PhantomModules || {};
window.PhantomModules._playerRegistry = playerRegistry;

// ─── Theme Detection ────────────────────────────────────────────────────────
function getCurrentAsciinemaTheme() {
    const scheme = document.body.getAttribute('data-md-color-scheme');
    return scheme === 'slate' ? PLAYER_CONFIG.themes.dark : PLAYER_CONFIG.themes.light;
}

// ─── Helper: Resolve cast file paths ────────────────────────────────────────
function resolveCastFilePath(path) {
    // If path starts with / or http, return as-is (absolute path or URL)
    // noinspection HttpUrlsUsage - Support both HTTP and HTTPS for flexibility
    if (path.startsWith('/') || path.startsWith('http://') || path.startsWith('https://')) {
        return path;
    }

    // If path doesn't contain ../, assume it's relative to docs/assets/static/
    if (!path.includes('../')) {
        return '/assets/static/' + path;
    }

    // Otherwise, try to resolve relative path
    // Get current page path
    const currentPath = window.location.pathname;
    const pathParts = currentPath.split('/').filter(Boolean);

    // Remove filename from path
    if (pathParts[pathParts.length - 1].includes('.')) {
        pathParts.pop();
    }

    // Apply relative path
    const castPathParts = path.split('/');
    for (const part of castPathParts) {
        if (part === '..') {
            pathParts.pop();
        } else if (part !== '.') {
            pathParts.push(part);
        }
    }

    return '/' + pathParts.join('/');
}

// ─── Helper: Get player options from element attributes ─────────────────────
function getPlayerOptions(element) {
    return {
        cols: parseInt(element.getAttribute('data-cols')) || PLAYER_CONFIG.cols,
        rows: parseInt(element.getAttribute('data-rows')) || PLAYER_CONFIG.rows,
        autoPlay: element.getAttribute('data-autoplay') === 'true' || PLAYER_CONFIG.autoPlay,
        preload: element.getAttribute('data-preload') !== 'false' && PLAYER_CONFIG.preload,
        loop: element.getAttribute('data-loop') === 'true' || PLAYER_CONFIG.loop,
        startAt: parseFloat(element.getAttribute('data-start-at')) || PLAYER_CONFIG.startAt,
        speed: parseFloat(element.getAttribute('data-speed')) || PLAYER_CONFIG.speed,
        theme: getCurrentAsciinemaTheme(),
        poster: element.getAttribute('data-poster') || PLAYER_CONFIG.poster,
        fit: element.getAttribute('data-fit') === 'true' || PLAYER_CONFIG.fit,
        terminalFontSize: element.getAttribute('data-font-size') || PLAYER_CONFIG.fontSize
    };
}

// ─── Helper: Mark pre elements to avoid badges ─────────────────────────────
function markPreElementsNoBadge(element) {
    setTimeout(function() {
        const preElements = element.querySelectorAll('pre');
        preElements.forEach(function(pre) {
            pre.setAttribute('data-no-badge', 'true');
        });
    }, 100);
}

// ─── Helper: Create and initialize Asciinema player ─────────────────────────
function createAsciinemaPlayer(element, castFile, playerOptions) {
    // Register player for theme-change recreation
    playerRegistry.set(element, { castFile: castFile, options: playerOptions });

    // Add loading state and spinner
    element.classList.add('loading');
    const spinner = document.createElement('div');
    spinner.className = 'player-spinner';
    spinner.innerHTML = '<div class="spinner-inner"></div>';
    element.appendChild(spinner);

    // Resolve cast file path
    const resolvedPath = resolveCastFilePath(castFile);

    try {
        // Use promise to handle async loading
        // noinspection JSUnresolvedVariable
        const playerPromise = AsciinemaPlayer.create(resolvedPath, element, playerOptions);

        // Handle player ready state
        if (playerPromise && typeof playerPromise.then === 'function') {
            playerPromise.then(function() {
                // Remove loading state
                element.classList.remove('loading');
                if (spinner.parentNode) {
                    spinner.remove();
                }
                // Mark any pre elements inside the player to avoid badges
                markPreElementsNoBadge(element);
            }).catch(function(error) {
                console.error('Failed to create Asciinema player:', error);
                element.classList.remove('loading');
                if (spinner.parentNode) {
                    spinner.remove();
                }
                element.innerHTML = '<div class="asciinema-error">Failed to load terminal recording</div>';
            });
        } else {
            // If not a promise, assume synchronous creation
            setTimeout(function() {
                element.classList.remove('loading');
                if (spinner.parentNode) {
                    spinner.remove();
                }
                // Mark any pre elements inside the player to avoid badges
                markPreElementsNoBadge(element);
            }, 500);
        }
    } catch (error) {
        console.error('Failed to create Asciinema player:', error);
        element.classList.remove('loading');
        if (spinner && spinner.parentNode) {
            spinner.remove();
        }
        element.innerHTML = '<div class="asciinema-error">Failed to load terminal recording</div>';
    }
}

// ─── Reinitialize all players (theme change) ────────────────────────────────
function reinitializeAllPlayers() {
    playerRegistry.forEach(function(entry, element) {
        // Clear rendered player
        element.innerHTML = '';
        element.classList.remove('initialized');

        // Rebuild options with the new theme
        const updatedOptions = getPlayerOptions(element);

        // Recreate the player
        createAsciinemaPlayer(element, entry.castFile, updatedOptions);
        element.classList.add('initialized');
    });
}

// ─── Define initialization function for lazy loading ────────────────────────
window.PhantomModules.initAsciinema = function() {
    // Find all asciinema player elements
    const playerElements = document.querySelectorAll('.asciinema-player:not(.initialized)');

    playerElements.forEach(function(element) {
        const castFile = element.getAttribute('data-cast-file');
        const playerId = element.getAttribute('id') || 'player-' + Math.random().toString(36).substring(2, 11);

        if (!castFile) {
            console.error('No cast file specified for player element');
            return;
        }

        // Get player configuration
        const playerOptions = getPlayerOptions(element);

        // Set ID if not already set
        if (!element.id) {
            element.id = playerId;
        }

        // Mark as initialized
        element.classList.add('initialized');

        // Create player using helper function
        createAsciinemaPlayer(element, castFile, playerOptions);
    });
};

// ─── Traditional loading (backward compatibility) ───────────────────────────
document.addEventListener('DOMContentLoaded', function() {
    // If AsciinemaPlayer is already loaded (non-lazy loading), initialize immediately
    if (typeof AsciinemaPlayer !== 'undefined' && !window.PhantomModules.asciinemaInitialized) {
        window.PhantomModules.asciinemaInitialized = true;
        window.PhantomModules.initAsciinema();
    }
});

// ─── Observers ──────────────────────────────────────────────────────────────
if (typeof MutationObserver !== 'undefined') {
    // Helper function to initialize a player element
    function initializePlayer(element) {
        const castFile = element.getAttribute('data-cast-file');
        // noinspection JSUnresolvedVariable
        if (castFile && typeof AsciinemaPlayer !== 'undefined') {
            element.classList.add('initialized');

            // Get player configuration using the helper function
            const playerOptions = getPlayerOptions(element);

            // Create player using helper function
            createAsciinemaPlayer(element, castFile, playerOptions);
        }
    }

    // Watch for dynamically added player elements (e.g., when switching tabs)
    new MutationObserver(function(mutations) {
        mutations.forEach(function(mutation) {
            mutation.addedNodes.forEach(function(node) {
                if (node.nodeType === 1) { // Element node
                    const players = node.querySelectorAll ? node.querySelectorAll('.asciinema-player:not(.initialized)') : [];
                    players.forEach(initializePlayer);
                }
            });
        });
    }).observe(document.body, { childList: true, subtree: true });

    // Watch for MkDocs Material theme toggle (data-md-color-scheme changes)
    new MutationObserver(function(mutations) {
        for (let i = 0; i < mutations.length; i++) {
            if (mutations[i].attributeName === 'data-md-color-scheme') {
                reinitializeAllPlayers();
                break;
            }
        }
    }).observe(document.body, { attributes: true, attributeFilter: ['data-md-color-scheme'] });
}
