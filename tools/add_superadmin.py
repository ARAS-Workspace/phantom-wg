"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

Add a superadmin account to auth.db. The password comes on stdin, one line,
and from nowhere else: no argument and no environment variable carries it.

Runs inside the auth image as `python -m tools.add_superadmin` from the
directory that holds auth_service/, started by the daemon's add-superadmin
tool with stdin piped. The account takes the service's own rules:
CreateUserRequest for the name and the password policy, hash_password,
AuthDB.create_user, and a user_created row in the audit log. One result line
is printed; the password is never printed.

Result lines and exit codes:
  SUPERADMIN_CREATED=<name>  0
  USAGE                      2
  STDIN_IS_A_TERMINAL        3
  INVALID_USERNAME           4
  WEAK_PASSWORD              5
  DATABASE_NOT_FOUND         6
  USER_ALREADY_EXISTS        7
"""

from __future__ import annotations

import argparse
import sys
from typing import NoReturn, TextIO

from pydantic import ValidationError

from auth_service.crypto.password import hash_password
from auth_service.db.repository import open_auth_db, resolve_db_path
from auth_service.errors import AuthDatabaseError
from auth_service.models import CreateUserRequest

ROLE = "superadmin"

EXIT_CODES = {
    "USAGE": 2,
    "STDIN_IS_A_TERMINAL": 3,
    "INVALID_USERNAME": 4,
    "WEAK_PASSWORD": 5,
    "DATABASE_NOT_FOUND": 6,
    "USER_ALREADY_EXISTS": 7,
}


class _Arguments(argparse.ArgumentParser):
    """argparse names the arguments it refuses, values included; this parser prints USAGE only."""

    def error(self, message: str) -> NoReturn:
        print("USAGE")
        raise SystemExit(EXIT_CODES["USAGE"])


def _result(name: str) -> int:
    print(name)
    return EXIT_CODES[name]


def _read_password(stdin: TextIO) -> str:
    return stdin.readline().removesuffix("\n").removesuffix("\r")


def main(argv: list[str] | None = None, stdin: TextIO | None = None) -> int:
    source = sys.stdin if stdin is None else stdin
    parser = _Arguments(prog="add_superadmin", add_help=False)
    parser.add_argument("--db-dir", required=True)
    parser.add_argument("--username", required=True)
    args = parser.parse_args(argv)

    # A terminal would echo the password as it is typed.
    if source.isatty():
        return _result("STDIN_IS_A_TERMINAL")

    # The error of a refused value holds the value: it is read here, never printed.
    try:
        request = CreateUserRequest(username=args.username, password=_read_password(source))
    except ValidationError as error:
        fields = {str(item["loc"][0]) for item in error.errors() if item["loc"]}
        return _result("INVALID_USERNAME" if "username" in fields else "WEAK_PASSWORD")

    # Checked before the connection: opening a missing auth.db would create it.
    try:
        db_path = resolve_db_path(args.db_dir)
    except AuthDatabaseError:
        return _result("DATABASE_NOT_FOUND")

    db = open_auth_db(db_path)
    try:
        try:
            user = db.create_user(request.username, hash_password(request.password), role=ROLE)
        except AuthDatabaseError:
            return _result("USER_ALREADY_EXISTS")
        db.add_audit_log(
            action="user_created",
            detail={"username": user.username, "role": ROLE, "by": "host"},
            user_id=user.id,
        )
    finally:
        db.close()

    print(f"SUPERADMIN_CREATED={user.username}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
