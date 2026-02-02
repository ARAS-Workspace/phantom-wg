#!/usr/bin/env python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Phantom Deployment Wizard - Streamlit UI
Modern and privacy-focused deployment portal for Phantom-WG servers

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
"""

import streamlit as st
import json
from pathlib import Path

# Import lib functions
from fragments.lib import (
    inject_custom_style,
    show_progress_sidebar
)

# Import fragment architecture components
from fragments.lib.wizard_controller import WizardController
from fragments.lib.state_manager import WizardState
from fragments.token_step import token_step_fragment
from fragments.aup_step import aup_step_fragment
from fragments.ssh_step import ssh_step_fragment
from fragments.provider_step import provider_step_fragment
from fragments.region_step import region_step_fragment
from fragments.os_step import os_step_fragment
from fragments.flavor_step import flavor_step_fragment
from fragments.quote_step import quote_step_fragment
from fragments.deployment_preview_step import deployment_preview_step_fragment
from fragments.deployment_process_step import deployment_process_step_fragment
from fragments.complete_step import complete_step_fragment


def init_session_state():
    """Initialize session state variables for multi-server deployment"""
    # Use WizardState for fragment architecture
    WizardState.init()

    # Keep compatibility with existing code
    if 'current_step' not in st.session_state:
        st.session_state.current_step = 0

    # Token state (shared between both servers)
    if 'token' not in st.session_state:
        st.session_state.token = None

    if 'token_info' not in st.session_state:
        st.session_state.token_info = None

    # AUP state (shared)
    if 'aup_accepted' not in st.session_state:
        st.session_state.aup_accepted = False

    # Multi-server state (flexible array structure for future expansion)
    if 'servers' not in st.session_state:
        st.session_state.servers = [
            {
                "type": "phantom",
                "name": "Phantom-WG Server",
                "provider": None,
                "region": None,
                "os": None,
                "flavor": None,
                "ssh_public_key": None,
                "days": None,
                "quote": None,
                "regions_cache": None,
                "os_cache": None,
                "flavors_cache": None,
                "deployment_config": {}
            }
            # Exit server can be added here in the future
        ]

    # Current server being configured (0=phantom, 1=exit)
    if 'current_server_index' not in st.session_state:
        st.session_state.current_server_index = 0


def wizard_form():
    """Main wizard form with progressive steps for multi-server deployment"""

    # Load step configuration from sidebar.json
    config_path = Path(__file__).parent / "configurations" / "sidebar.json"
    with open(config_path, 'r') as f:
        sidebar_config = json.load(f)

    # Build step_names list from step_index (sorted by index value)
    step_index = sidebar_config.get("step_index", {})
    step_names = [name for name, idx in sorted(step_index.items(), key=lambda x: x[1])]

    current_step_name = step_names[st.session_state.current_step] if st.session_state.current_step < len(
        step_names) else "complete"
    show_progress_sidebar(current_step_name)

    # Main content container
    st.title(":wizard: Deployment Wizard")
    st.markdown("---")

    # Use fragment architecture for all steps (0-12)
    wizard = WizardController()

    # Register all fragment steps
    wizard.register_step(0, token_step_fragment)
    wizard.register_step(1, aup_step_fragment)
    wizard.register_step(2, ssh_step_fragment)
    wizard.register_step(3, provider_step_fragment)
    wizard.register_step(4, region_step_fragment)
    wizard.register_step(5, os_step_fragment)
    wizard.register_step(6, flavor_step_fragment)
    wizard.register_step(7, quote_step_fragment)
    wizard.register_step(8, deployment_preview_step_fragment)
    wizard.register_step(9, deployment_process_step_fragment)
    wizard.register_step(10, complete_step_fragment)

    # Render the current step using fragment
    wizard.render_current_step()


def main():
    """Main application entry point"""
    # Page configuration
    st.set_page_config(
        page_title="Phantom Deployment Wizard",
        page_icon=":ghost:",
        initial_sidebar_state="expanded"
    )

    # Hide Streamlit branding
    inject_custom_style()

    # Initialize session state
    init_session_state()

    # Run wizard form
    wizard_form()


if __name__ == "__main__":
    main()
