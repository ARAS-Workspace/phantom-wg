"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Token Step Fragment

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
"""

import streamlit as st
import time
from .lib.api import fetch_api
from .lib.navigation import NavigationManager
from .lib.state_manager import WizardState
from .lib.utils import spinner


@st.fragment
def token_step_fragment():
    """Token validation step as fragment - no full page rerun!"""
    st.markdown("### :lock: SporeStack Token")

    st.info(
        ":bulb: Enter your SporeStack token to continue. "
        "Your token is required to manage servers and payments."
    )

    # Use fragment-specific key to prevent state conflicts
    token_input = st.text_input(
        "SporeStack Token:",
        placeholder="ss_t_...",
        key="token_fragment_input",
        help="Your SporeStack token (format: ss_t_...)"
    )

    # Validate button - only if token is entered
    if token_input and token_input.strip():
        if st.button(
            ":white_check_mark: Validate & Continue",
            use_container_width=True,
            type="primary",
            key="token_validate_btn"
        ):
            with spinner("Validating token..."):
                # Validate token via API
                token_info = fetch_api(f"/token/{token_input}/info")

                if token_info and isinstance(token_info, dict):
                    # Save to session state
                    WizardState.set('token', token_input)
                    WizardState.set('token_info', token_info)

                    st.success(":white_check_mark: Token validated successfully!")
                    time.sleep(0.5)  # Brief pause for user feedback

                    # Navigate to next step - fragments need explicit rerun
                    NavigationManager.next(1)
                    st.rerun()
                else:
                    st.error(":x: Invalid token. Please check and try again.")
    else:
        # Show disabled button when no token
        st.button(
            ":white_check_mark: Validate & Continue",
            use_container_width=True,
            type="primary",
            disabled=True,
            help="Enter a SporeStack token to continue",
            key="token_validate_btn_disabled"
        )