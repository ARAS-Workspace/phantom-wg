// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Phantom-WG for macOS — application entry point.
//
// ─── HOW TO READ THIS CODEBASE ────────────────────────────────────────
//
// Production sources carry no prose. Comments here do not explain, argue
// or restate what the code does — the code is the only authority on its
// own behaviour. What a comment may carry is a POINTER to where a claim
// is proven or where a decision is recorded.
//
// Three markers, plus the directives the linter itself reads:
//
//   /// @witness <Workflow>
//   /// @witness <Workflow>.<step>
//       The PhantomTestEngine harness drives this symbol and asserts on
//       it. `<Workflow>` names a workflow FAMILY under
//       `Phantom-WG-MacOS/PhantomTestEngine/workflows/` — one type,
//       sometimes continued across `+`-suffixed files — whose header says
//       what the family measures; some headers list the scenarios one by
//       one, others say why they do not. `<step>` names one method in that
//       family, which may live in any of its files. Grep the name to read
//       the actual assertions. A method carrying several workflow markers
//       is exercised from several angles.
//
//   /// @adr <NNNN>
//       The decision behind this shape is recorded in
//       `Documentation/ADR/English/<NNNN>-*.md`. The ADR carries the
//       reasoning, the alternatives and what was rejected. The code does
//       not repeat it.
//
//   // MARK: -
//       Navigation. It may name what a group of symbols is for, and a few
//       do carry a parenthetical about the group's shape — but a MARK is
//       never where a behavioural guarantee is recorded. That is a marker
//       or the ADR.
//
//   SwiftLint directives
//       Read by the linter, never by a reader. Carries no claim about
//       behaviour. (Not spelled out here: writing one would make this
//       legend a directive rather than a description of one.)
//
// The markers are NOT exhaustive. An unmarked symbol usually has no
// harness witness — but not always: the harness asserts on some symbols
// that carry no marker yet (`ConfParser.parse` and `TunnelResetReply.read`
// among them). So absence means "not annotated", never "not tested", and
// it never means the symbol is wrong or unimportant. Unwitnessed symbols
// are being collected deliberately rather than annotated, so the gap
// stays visible instead of being explained away.
//
// The test engine itself is documented differently: every file under
// `PhantomTestEngine/` opens with a header naming what it is and, where
// it drives something, what it drives; some also name what the file
// cannot prove. Read that header before reading its body — the bodies are
// bare on purpose.
//
// ──────────────────────────────────────────────────────────────────────

import SwiftUI

@main
@MainActor
struct PhantomApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var loc = LocalizationManager.shared

    var body: some Scene {
        Window(loc.t("app_title"), id: SceneID.mainWindow) {
            MainWindowRoot(host: appDelegate.runtimeHost)
                .environment(loc)
                .tint(Color.accentColor)
                .frame(
                    minWidth: WindowSizing.minimum.width,
                    idealWidth: WindowSizing.ideal.width,
                    maxWidth: .infinity,
                    minHeight: WindowSizing.minimum.height,
                    idealHeight: WindowSizing.ideal.height,
                    maxHeight: .infinity
                )
        }
        .windowResizability(.contentMinSize)
        .defaultSize(WindowSizing.ideal)
        .commands {
            WindowSizeCommands(loc: loc)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(loc)
                .environment(appDelegate.runtimeHost)
        } label: {
            Image("MenuBarIcon")
                .accessibilityLabel(Text(loc.t("app_title")))
        }
        .menuBarExtraStyle(.menu)
    }
}
