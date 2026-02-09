"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Utility functions for server configuration

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
"""

import streamlit as st
import paramiko
from contextlib import contextmanager, AbstractContextManager
from typing import cast, Generator
from io import StringIO
import base64
import binascii


@contextmanager
def spinner(text: str = "In progress...") -> Generator[None, None, None]:
    """Typed context manager wrapper for st.spinner

    st.spinner is decorated with @contextmanager which returns AbstractContextManager
    at runtime, but streamlit annotates it as Iterator[None]. This wrapper provides
    correct typing for all call sites.
    """
    with cast(AbstractContextManager[None], cast(object, st.spinner(text))):
        yield


def get_current_server():
    """Get the current server being configured"""
    return st.session_state.servers[st.session_state.current_server_index]


def update_current_server(key, value):
    """Update a field in the current server"""
    st.session_state.servers[st.session_state.current_server_index][key] = value


def generate_ssh_keypair():
    """Generate RSA SSH key pair and return (private_key, public_key)"""
    key = paramiko.RSAKey.generate(4096)

    # Get private key
    private_key_file = StringIO()
    key.write_private_key(private_key_file)
    private_key = private_key_file.getvalue()

    # Get public key
    public_key = f"{key.get_name()} {key.get_base64()}"

    return private_key, public_key


def validate_ssh_public_key(key_string):
    """
    Validate an SSH public key string using paramiko

    Args:
        key_string: SSH public key string (e.g., "ssh-rsa AAAAB3... comment")

    Returns:
        tuple: (is_valid, normalized_key, error_message)
        - is_valid: Boolean indicating if the key is valid
        - normalized_key: Properly formatted key string (if valid)
        - error_message: Error description (if invalid)
    """
    if not key_string or not key_string.strip():
        return False, None, "Key cannot be empty"

    key_string = key_string.strip()

    # Check for common SSH key formats
    valid_prefixes = ['ssh-rsa', 'ssh-dss', 'ssh-ed25519', 'ecdsa-sha2-nistp256',
                      'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521']

    # Split the key into parts
    parts = key_string.split()

    if len(parts) < 2:
        return False, None, "Invalid key format. Expected format: 'ssh-rsa AAAAB3...'"

    key_type = parts[0]
    key_data = parts[1]

    # Check if key type is valid
    if key_type not in valid_prefixes:
        return False, None, f"Unsupported key type: {key_type}. Supported types: {', '.join(valid_prefixes)}"

    # Validate base64 encoding
    try:
        # Check if it's valid base64
        decoded = base64.b64decode(key_data, validate=True)
    except (ValueError, binascii.Error):
        return False, None, "Invalid base64 encoding in key data"

    # Try to load the key with paramiko based on key type
    try:
        if key_type == 'ssh-rsa':
            # Try to create an RSA key from the data - validation only
            _ = paramiko.RSAKey(data=decoded)
        elif key_type == 'ssh-ed25519':
            _ = paramiko.Ed25519Key(data=decoded)
        elif key_type.startswith('ecdsa'):
            _ = paramiko.ECDSAKey(data=decoded)
        else:
            # For other types, just validate the structure
            pass

        # If we get here, the key is valid
        # Return normalized key (first two parts only, without comment)
        normalized_key = f"{parts[0]} {parts[1]}"
        return True, normalized_key, None

    except (paramiko.SSHException, ValueError, TypeError) as e:
        # More specific error handling for paramiko
        return False, None, f"Invalid {key_type} key: {str(e)}"
