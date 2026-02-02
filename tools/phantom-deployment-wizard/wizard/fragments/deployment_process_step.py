"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Deployment Process Step Fragment

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
"""

import streamlit as st
import time
import base64
import yaml
from pathlib import Path
from .lib.api import post_api, fetch_api
from .lib.navigation import NavigationManager


def get_cloud_init_config():
    """
    Loads and returns the cloud-init configuration from YAML file

    Returns:
        str: Cloud-init configuration as a YAML string

    Raises:
        FileNotFoundError: If cloud-init.yml file is not found
        yaml.YAMLError: If YAML file is malformed
    """
    config_path = Path(__file__).parent.parent / "scripts" / "cloud-init.yml"

    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            # Read the entire file as string (cloud-init expects string format)
            cloud_init_content = f.read()

        # Validate that it's valid YAML
        yaml.safe_load(cloud_init_content)

        return cloud_init_content.strip()

    except FileNotFoundError:
        raise FileNotFoundError(f"Cloud-init configuration file not found at: {config_path}")
    except yaml.YAMLError as e:
        raise yaml.YAMLError(f"Invalid YAML in cloud-init configuration: {e}")




@st.fragment
def deployment_process_step_fragment():
    """Deployment process as fragment - direct implementation"""
    st.markdown("### :rocket: Deployment Process")

    # Initialize deployment state
    if 'deployment_initiated' not in st.session_state:
        st.session_state.deployment_initiated = False
    if 'deployment_response' not in st.session_state:
        st.session_state.deployment_response = None

    # Deployment Request section with expander
    st.markdown("### :outbox_tray: Deployment Request")

    with st.expander(":clipboard: View Deployment Request", expanded=False):
        for idx, server in enumerate(st.session_state.servers):
            server_name = server.get('name', 'Unknown Server')

            # Extract server configuration with safe access
            flavor = server.get('flavor', {})
            os_info = server.get('os', {})
            provider_info = server.get('provider', {})
            region_info = server.get('region', {})

            # Build request body
            request_body = {
                "flavor": flavor.get('slug', ''),
                "ssh_key": server.get('ssh_public_key', ''),
                "operating_system": os_info.get('slug', ''),
                "provider": provider_info.get('slug', ''),
                "autorenew": True,
                "days": server.get('days', 1),
                "region": region_info.get('slug', '')
            }

            st.markdown(f"#### {server_name}")
            st.json(request_body)

    # Cloud Init Configuration section
    st.markdown("### :cloud: Cloud Init Configuration")

    with st.expander(":page_facing_up: View Cloud Init Script", expanded=False):
        cloud_init = get_cloud_init_config()
        st.code(cloud_init, language="yaml")

    st.markdown("---")

    # Deploy button - only show if not deployed yet
    if not st.session_state.deployment_initiated:
        if st.button(":rocket: Deploy Server", use_container_width=True, type="primary", key="deploy_server_btn"):
            st.session_state.deployment_initiated = True

            with st.spinner("Deploying server... This may take a moment."):
                deployment_responses = []

                for idx, server in enumerate(st.session_state.servers):
                    server_name = server.get('name', 'Unknown Server')

                    # Extract server configuration
                    flavor = server.get('flavor', {})
                    os_info = server.get('os', {})
                    provider_info = server.get('provider', {})
                    region_info = server.get('region', {})

                    # Get cloud-init configuration from function
                    cloud_init_config = get_cloud_init_config()

                    # Encode user_data based on provider requirements
                    if provider_info.get('slug') == 'vultr':
                        # Vultr requires base64 encoding
                        user_data = base64.b64encode(cloud_init_config.encode()).decode()
                    else:
                        # DigitalOcean accepts plain text
                        user_data = cloud_init_config

                    # Build request body with cloud-init
                    request_body = {
                        "flavor": flavor.get('slug', ''),
                        "ssh_key": server.get('ssh_public_key', ''),
                        "operating_system": os_info.get('slug', ''),
                        "provider": provider_info.get('slug', ''),
                        "autorenew": True,
                        "days": server.get('days', 1),
                        "region": region_info.get('slug', ''),
                        "user_data": user_data  # Add cloud-init configuration
                    }

                    # POST request
                    response = post_api(
                        f"/token/{st.session_state.token}/servers",
                        data=request_body
                    )

                    # Save machine_id to deployment config if successful
                    if 'machine_id' in response and response.get('machine_id'):
                        server['deployment_config']['machine_id'] = response['machine_id']

                    deployment_responses.append({
                        "server": server_name,
                        "response": response
                    })

                st.session_state.deployment_response = deployment_responses
                st.rerun()

    # Display deployment response
    if st.session_state.deployment_response:
        st.markdown("### :inbox_tray: Deployment Response")
        st.markdown("---")

        all_successful = True

        for result in st.session_state.deployment_response:
            server_name = result['server']
            response = result['response']

            st.markdown(f"#### {server_name}")

            # Check success status for navigation
            if 'error' in response:
                all_successful = False
                st.error(f":x: Deployment failed: {response.get('error', 'Unknown error')}")
            else:
                st.success(":white_check_mark: Deployment successful")
                if 'machine_id' in response:
                    st.info(f":id: Machine ID: `{response['machine_id']}`")

            # JSON output in expander
            with st.expander(":clipboard: View Full Response"):
                st.json(response)

        st.markdown("---")

        # Navigation based on deployment result
        if all_successful:
            # Initialize check server states
            if 'check_initiated' not in st.session_state:
                st.session_state.check_initiated = False
            if 'ip_check_complete' not in st.session_state:
                st.session_state.ip_check_complete = False
            if 'server_ipv4' not in st.session_state:
                st.session_state.server_ipv4 = None
            if 'server_info' not in st.session_state:
                st.session_state.server_info = None
            if 'ip_poll_count' not in st.session_state:
                st.session_state.ip_poll_count = 0

            # Check Server Section
            st.markdown("### :satellite: Server Availability Check")

            # Get machine_id for checking
            phantom_server = st.session_state.servers[0]
            machine_id = phantom_server.get('deployment_config', {}).get('machine_id')

            # Auto-start check after successful deployment
            if not st.session_state.check_initiated:
                st.info(":hourglass_flowing_sand: Auto-starting server availability check...")
                st.session_state.check_initiated = True
                time.sleep(0.5)
                st.rerun()

            # Check is initiated - start validation
            max_ip_attempts = 60  # 5 minutes (60 * 5 seconds)

            # IP Address Check
            st.markdown("#### :mag: IP Address Assignment")
            ip_status_placeholder = st.empty()

            if not st.session_state.ip_check_complete:
                if st.session_state.ip_poll_count < max_ip_attempts:
                    with ip_status_placeholder.container():
                        st.info(f":mag: Polling for IP address... (Attempt {st.session_state.ip_poll_count + 1}/{max_ip_attempts})")
                        # Fetch server info
                        server_info = fetch_api(f"/token/{st.session_state.token}/servers/{machine_id}")

                    if server_info and 'ipv4' in server_info and server_info['ipv4']:
                        st.session_state.server_ipv4 = server_info['ipv4']
                        st.session_state.server_info = server_info
                        st.session_state.ip_check_complete = True
                        st.session_state.ip_poll_count = 0  # Reset counter
                        # Save IPv4 to deployment config
                        phantom_server['deployment_config']['ipv4'] = server_info['ipv4']

                        with ip_status_placeholder.container():
                            st.success(f":white_check_mark: IP Address: `{server_info['ipv4']}`")
                        time.sleep(1)
                        st.rerun()
                    else:
                        st.session_state.ip_poll_count += 1
                        time.sleep(5)
                        st.rerun()
                else:
                    with ip_status_placeholder.container():
                        st.error(":x: Timeout: IP address not assigned after 5 minutes")
                        if st.button(":arrows_counterclockwise: Retry IP Check", key="ip_retry_btn"):
                            st.session_state.ip_poll_count = 0
                            st.rerun()

                    # Show restart check button
                    st.markdown("---")
                    if st.button(":leftwards_arrow_with_hook: Restart Server Check", use_container_width=True, key="restart_check_btn"):
                        st.session_state.check_initiated = False
                        st.session_state.ip_check_complete = False
                        st.session_state.ip_poll_count = 0
                        st.rerun()
            else:
                st.success(f":white_check_mark: IP Address: `{st.session_state.server_ipv4}`")
                with st.expander(":clipboard: View Server Information"):
                    st.json(st.session_state.server_info)

            # Navigation based on check completion
            st.markdown("---")
            if st.session_state.ip_check_complete:
                # IP check passed - enable Next button
                st.success(":tada: Server is ready! Cloud-init will automatically install Phantom-WG.")
                if st.button("Continue to Summary :arrow_right:", use_container_width=True, type="primary", key="complete_next_btn"):
                    # Clear check states for potential future use
                    st.session_state.check_initiated = False
                    st.session_state.ip_check_complete = False
                    st.session_state.ip_poll_count = 0
                    NavigationManager.next(10)  # Go directly to complete_step
                    st.rerun()
            else:
                # Checks in progress or failed - disabled Next button
                st.button("Continue to Summary :arrow_right:", use_container_width=True, disabled=True,
                         help="Wait for server availability checks to complete", key="complete_next_waiting_btn")
        else:
            # Failed: Show Back to Preview and disabled Next
            col1, col2 = st.columns(2)
            with col1:
                if st.button(":leftwards_arrow_with_hook: Back to Preview", use_container_width=True, key="deployment_back_failed_btn"):
                    # Reset deployment state
                    st.session_state.deployment_initiated = False
                    st.session_state.deployment_response = None
                    NavigationManager.back(8)
                    st.rerun()
            with col2:
                st.button("Next: Install Phantom :arrow_right:", use_container_width=True, disabled=True,
                         help="Fix deployment errors before proceeding", key="deployment_next_disabled_btn")
    else:
        # No deployment yet - show back button only
        if st.button(":leftwards_arrow_with_hook: Back to Preview", use_container_width=True, key="deployment_back_btn"):
            NavigationManager.back(8)
            st.rerun()