// Mode Toggle (CLI / API) for asciinema player
document.addEventListener('click', function(e) {
    const btn = e.target.closest('.asciinema-mode-toggle .mode-btn');
    if (!btn || btn.classList.contains('active')) return;

    const toggle = btn.closest('.asciinema-mode-toggle');
    const container = btn.closest('.asciinema-player-container');
    if (!container) return;

    const player = container.querySelector('.asciinema-player');
    if (!player) return;

    const mode = btn.getAttribute('data-mode');
    const castCli = player.getAttribute('data-cast-file-cli') || player.getAttribute('data-cast-file');
    const castApi = player.getAttribute('data-cast-file-api');
    if (!castApi) return;

    // Store original CLI path on first toggle
    if (!player.getAttribute('data-cast-file-cli')) {
        player.setAttribute('data-cast-file-cli', castCli);
    }

    // Update active button
    toggle.querySelectorAll('.mode-btn').forEach(function(b) { b.classList.remove('active'); });
    btn.classList.add('active');

    // Determine new cast file
    const newCast = mode === 'api' ? castApi : castCli;
    player.setAttribute('data-cast-file', newCast);

    // Recreate the player via PhantomModules
    if (window.PhantomModules && window.PhantomModules._playerRegistry) {
        window.PhantomModules._playerRegistry.delete(player);
    }
    player.innerHTML = '';
    player.classList.remove('initialized');

    if (window.PhantomModules && window.PhantomModules.initAsciinema) {
        window.PhantomModules.initAsciinema();
    }
});
