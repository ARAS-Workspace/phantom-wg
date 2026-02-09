"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

SSH Step Fragment

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
"""

import streamlit as st
from .lib.utils import get_current_server, update_current_server, generate_ssh_keypair, validate_ssh_public_key, spinner
from .lib.navigation import NavigationManager


@st.fragment
def ssh_step_fragment():
    """SSH key generation and import as fragment - direct implementation"""
    # Set current server index
    st.session_state.current_server_index = 0
    server = get_current_server()

    st.markdown("### Server Keys")

    st.info(":lock: Generate a new SSH key pair or import an existing public key for secure server access.")

    # Initialize session states for key mode
    if 'ssh_key_mode' not in st.session_state:
        st.session_state.ssh_key_mode = None  # None, 'generate', or 'import'

    if 'import_key_text' not in st.session_state:
        st.session_state.import_key_text = ""

    # Show keys if they exist
    if server['ssh_public_key']:
        st.success(":white_check_mark: SSH public key configured successfully!")

        st.markdown("#### Public Key")
        st.code(server['ssh_public_key'], language="text")

        # Show private key if available in session (temporary display only for generated keys)
        if 'temp_private_key' in st.session_state and st.session_state.temp_private_key:
            st.markdown("#### Private Key (Generated)")
            st.warning(":warning: **Security Notice**: Private key shown in plaintext. Store it securely!")
            st.code(st.session_state.temp_private_key, language="text")
            st.warning(":warning: **Important**: Save your private key NOW. It will not be stored and cannot be recovered after leaving this page!")

        # Clear/reset button
        if st.button(":arrows_counterclockwise: Use Different Key", use_container_width=True, key="ssh_reset_btn"):
            update_current_server('ssh_public_key', None)
            server['deployment_config']['ssh_public_key'] = None
            if 'temp_private_key' in st.session_state:
                del st.session_state.temp_private_key
            st.session_state.ssh_key_mode = None
            st.session_state.import_key_text = ""
            st.rerun()

    # Key configuration options (only show if no key is configured)
    elif not server['ssh_public_key']:
        # Two buttons for different modes
        col1, col2 = st.columns(2)

        with col1:
            if st.button(":key: Generate New Keys", use_container_width=True, type="primary", key="ssh_generate_mode_btn"):
                st.session_state.ssh_key_mode = 'generate'
                st.rerun()

        with col2:
            if st.button(":inbox_tray: Import Existing Public Key", use_container_width=True, type="secondary", key="ssh_import_mode_btn"):
                st.session_state.ssh_key_mode = 'import'
                st.rerun()

        # Show the appropriate interface based on mode
        if st.session_state.ssh_key_mode == 'generate':
            st.markdown("---")
            st.markdown("#### Generate New SSH Key Pair")
            st.info("Click the button below to generate a new 4096-bit RSA key pair.")

            if st.button(":sparkles: Generate Keys Now", use_container_width=True, key="ssh_do_generate_btn"):
                with spinner("Generating SSH key pair..."):
                    private_key, public_key = generate_ssh_keypair()

                    # Store private key temporarily for display only (not in server state)
                    st.session_state.temp_private_key = private_key

                    # Only store public key in server state
                    update_current_server('ssh_public_key', public_key)
                    server['deployment_config']['ssh_public_key'] = public_key

                    st.rerun()

        elif st.session_state.ssh_key_mode == 'import':
            st.markdown("---")
            st.markdown("#### Import Existing SSH Public Key")
            st.info("Paste your SSH public key below. Supported formats: ssh-rsa, ssh-ed25519, ecdsa, ssh-dss")

            # Text area for key input
            import_key = st.text_area(
                "SSH Public Key",
                value=st.session_state.import_key_text,
                height=100,
                placeholder="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... user@host",
                key="ssh_import_text_area"
            )

            # Update session state when text changes
            if import_key != st.session_state.import_key_text:
                st.session_state.import_key_text = import_key

            # Validate and Import button
            if st.button(":white_check_mark: Validate and Import", use_container_width=True, key="ssh_validate_import_btn"):
                if import_key.strip():
                    with spinner("Validating SSH public key..."):
                        is_valid, normalized_key, error_msg = validate_ssh_public_key(import_key)

                        if is_valid:
                            # Store the normalized public key
                            update_current_server('ssh_public_key', normalized_key)
                            server['deployment_config']['ssh_public_key'] = normalized_key

                            # Clear import state
                            st.session_state.ssh_key_mode = None
                            st.session_state.import_key_text = ""

                            st.success("SSH public key validated and imported successfully!")
                            st.rerun()
                        else:
                            st.error(f":x: Invalid SSH public key: {error_msg}")
                else:
                    st.error("Please paste your SSH public key in the text area above.")

    st.markdown("---")

    # Navigation buttons (fragment style - no form)
    col1, col2 = st.columns(2)

    with col1:
        if st.button(
            ":leftwards_arrow_with_hook: Back",
            use_container_width=True,
            key="ssh_back_btn"
        ):
            # Clear SSH keys and temp private key when going back
            update_current_server('ssh_public_key', None)
            if 'temp_private_key' in st.session_state:
                del st.session_state.temp_private_key
            st.session_state.ssh_key_mode = None
            st.session_state.import_key_text = ""
            NavigationManager.back(1)  # Go to AUP step
            st.rerun()

    with col2:
        # Disable Next button if public key not generated
        key_exists = bool(server['ssh_public_key'])

        if st.button(
            "Next :arrow_right:",
            use_container_width=True,
            type="primary",
            disabled=not key_exists,
            key="ssh_next_btn"
        ):
            if server['ssh_public_key']:
                # Clear temp private key when moving forward
                if 'temp_private_key' in st.session_state:
                    del st.session_state.temp_private_key
                NavigationManager.next(3)  # Go to Provider step
                st.rerun()
            else:
                st.error("Please generate SSH keys before proceeding.")