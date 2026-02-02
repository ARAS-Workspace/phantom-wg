"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Complete Step Fragment

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
"""

import json
import streamlit as st
from textwrap import dedent
from .lib.navigation import NavigationManager


@st.fragment
def complete_step_fragment():
    """Complete step as fragment - direct implementation"""
    # Phantom-WG Server
    phantom_server = st.session_state.servers[0]
    st.markdown("## Phantom-WG Server")

    # Cloud-init Installation Status
    st.markdown("### :rocket: Installation Status")
    server_ipv4 = phantom_server.get('deployment_config', {}).get('ipv4')

    st.info(":white_check_mark: **Cloud-init is automatically installing Phantom-WG**")
    st.markdown("The installation will complete in approximately 5-10 minutes.")

    # Monitoring Instructions
    st.markdown("#### :bar_chart: How to Monitor Installation")

    if server_ipv4:
        st.markdown("You can monitor the installation progress using SSH:")

        # SSH connection command
        ssh_command = f"ssh root@{server_ipv4}"
        st.code(ssh_command, language="bash")

        st.markdown("Once connected, monitor the installation with:")

        # Log monitoring commands
        monitor_commands = dedent("""
            # Check cloud-init status
            cloud-init status --wait

            # View installation logs
            tail -f /var/log/cloud-init-output.log

            # Or view cloud-init output
            tail -f /var/log/phantom-install.log
        """).strip()
        st.code(monitor_commands, language="bash")
    else:
        st.warning("Server IP not available yet. Please wait for deployment to complete.")

    st.markdown("---")

    # Troubleshooting Section
    st.markdown("### :wrench: Troubleshooting")

    with st.expander(":warning: Cloud-init Installation Not Starting?", expanded=False):
        st.info("""
        **Your server has been successfully created!** :white_check_mark:

        If you see `status: done` when checking cloud-init but Phantom-WG installation hasn't started,
        the user-data script may not have been processed by the provider.

        Don't worry - you can install Phantom-WG manually using the commands below.
        """)

        if server_ipv4:
            st.markdown("#### Manual Installation Commands:")
            manual_install = dedent(f"""
                # Connect to your server
                ssh root@{server_ipv4}
                curl -sSL https://install.phantom.tc | bash
            """).strip()
            st.code(manual_install, language="bash")

            st.success("""
            :bulb: The installer will guide you through the setup process and configure everything automatically.
            """)
        else:
            st.warning("Server IP will be displayed once deployment completes.")

    st.markdown("---")

    # Deployment Configuration with expandable view and export
    st.markdown("#### Deployment Configuration")

    with st.expander(":clipboard: View Configuration JSON", expanded=False):
        st.json(phantom_server['deployment_config'])

        # Export button
        config_json = json.dumps(phantom_server['deployment_config'], indent=2)
        st.download_button(
            label=":floppy_disk: Export as JSON",
            data=config_json,
            file_name="phantom_deployment_config.json",
            mime="application/json",
            use_container_width=True,
            key="export_config_btn"
        )

    st.markdown("---")

    if st.button(":arrows_counterclockwise: Start Over", use_container_width=True, key="complete_start_over_btn"):
        # Reset all session state
        st.session_state.current_step = 0
        st.session_state.current_server_index = 0

        # Token state
        st.session_state.token = None
        st.session_state.token_info = None
        st.session_state.aup_accepted = False

        # Deployment state
        st.session_state.deployment_initiated = False
        st.session_state.deployment_response = None

        # Check server state
        st.session_state.ip_check_complete = False
        st.session_state.ssh_check_complete = False
        st.session_state.server_ipv4 = None
        st.session_state.server_info = None


        # Reset server (flexible array structure for future expansion)
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

        NavigationManager.next(0)
        st.rerun()