const ASCII_ART = `
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
`;

const COPYRIGHT = 'Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>';
const LICENSE =
  'Licensed under AGPL-3.0 — WireGuard® is a registered trademark of Jason A. Donenfeld.';

export function printConsoleBranding(): void {
  console.log(`%c${ASCII_ART}`, 'color: #0f62fe; font-family: monospace; font-weight: bold;');
  console.log(`%c${COPYRIGHT}`, 'color: #525252; font-family: monospace; font-size: 11px;');
  console.log(`%c${LICENSE}`, 'color: #525252; font-family: monospace; font-size: 10px;');
}
