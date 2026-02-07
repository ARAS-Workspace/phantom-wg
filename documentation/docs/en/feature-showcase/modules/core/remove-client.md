---
extra_javascript:
  - assets/javascripts/asciinema-player.js
  - assets/javascripts/mode-toggle.js
extra_css:
  - assets/stylesheets/mode-toggle.css
---

<div class="asciinema-player-container">
    <div class="asciinema-player-header">
        <h3>Phantom-WG</h3>
        <div class="asciinema-mode-toggle">
            <button class="mode-btn active" data-mode="api">API</button>
            <button class="mode-btn" data-mode="cli">CLI</button>
        </div>
    </div>
    <div class="asciinema-player-wrapper">
        <div class="asciinema-player"
             data-cast-file="recordings/feature-showcase/api/remove_client"
             data-cast-file-cli="recordings/feature-showcase/cli/remove_client"
             data-cols="120"
             data-rows="48"
             data-autoplay="false"
             data-loop="false"
             data-speed="1.5"
             data-font-size="small"
             data-poster="text">
        </div>
    </div>
</div>
