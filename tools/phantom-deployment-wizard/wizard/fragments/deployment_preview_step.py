"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Deployment Preview Step Fragment

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
"""

import streamlit as st
from .lib.navigation import NavigationManager


@st.fragment
def deployment_preview_step_fragment():
    """Deployment preview as fragment - direct implementation"""
    st.session_state.current_server_index = 0

    st.markdown("### Deployment Preview")

    phantom_server = st.session_state.servers[0]

    # Extract cost information from quote
    phantom_quote = phantom_server.get('quote', {})

    # Parse cost from quote - format: {"cents": 16, "usd": "$0.16"}
    def parse_cost(quote_data):
        if isinstance(quote_data, dict):
            # Check for 'usd' key first (primary format)
            if 'usd' in quote_data:
                usd_value = quote_data['usd']
                if isinstance(usd_value, str):
                    clean_cost = ''.join(c for c in usd_value if c.isdigit() or c == '.')
                    return float(clean_cost) if clean_cost else 0.0
                return float(usd_value) if usd_value else 0.0
            # Fallback to cents
            elif 'cents' in quote_data:
                return float(quote_data['cents']) / 100.0
        return 0.0

    phantom_amount = parse_cost(phantom_quote)
    total_cost = phantom_amount

    # Server summary
    st.markdown("#### Phantom-WG Server")

    phantom_flavor = phantom_server.get('flavor', {})
    phantom_size = phantom_flavor.get('name') or phantom_flavor.get('slug', 'N/A') if isinstance(phantom_flavor,
                                                                                                 dict) else 'N/A'

    st.markdown(f"**Provider:** {phantom_server.get('provider', {}).get('name', 'N/A')}")
    st.markdown(f"**Region:** {phantom_server.get('region', {}).get('name', 'N/A')}")
    st.markdown(f"**OS:** {phantom_server.get('os', {}).get('name', 'N/A')}")
    st.markdown(f"**Size:** {phantom_size}")
    st.markdown(f"**Days:** {phantom_server.get('days', 'N/A')}")
    st.markdown(f"**Cost:** ${phantom_amount:.2f}")

    with st.expander("View Full Configuration"):
        st.json(phantom_server['deployment_config'])

    st.markdown("---")

    # Total cost and balance check
    st.markdown(f"### Total Cost: ${total_cost:.2f}")

    # Check balance
    if st.session_state.get('token_info'):
        balance_value = st.session_state.token_info.get('balance_usd', 0)
        if isinstance(balance_value, str):
            token_balance = float(balance_value.replace('$', '').strip())
        else:
            token_balance = float(balance_value) if balance_value else 0.0

        if total_cost > token_balance:
            st.warning(
                ":warning: Insufficient Credit: Your token balance is lower than the total deployment cost. You may proceed, but deployment may fail.")

    st.markdown("---")

    # Navigation buttons (fragment style - no form)
    col1, col2 = st.columns(2)

    with col1:
        if st.button(
            "← Back",
            use_container_width=True,
            key="deployment_preview_back_btn"
        ):
            NavigationManager.back(7)  # Back to Quote step
            st.rerun()

    with col2:
        if st.button(
            "Proceed to Deployment →",
            use_container_width=True,
            type="primary",
            key="deployment_preview_next_btn"
        ):
            NavigationManager.next(9)  # Go to Deployment Process
            st.rerun()