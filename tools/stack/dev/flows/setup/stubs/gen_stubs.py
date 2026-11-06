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

Vendor stub generator: AST-based .pyi producer for bridge packages.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path


def _unparse(node: ast.expr | None) -> str:
    """Unparse an AST expression node back to source text."""
    if node is None:
        return ""
    return ast.unparse(node)


def _format_arg(arg: ast.arg) -> str:
    """Format a single function argument with optional annotation."""
    name = arg.arg
    if arg.annotation:
        return f"{name}: {_unparse(arg.annotation)}"
    return name


def _format_arguments(args: ast.arguments) -> str:
    """Format a full argument list (positional, defaults, *args, **kwargs)."""
    parts: list[str] = []

    # positional-only args
    posonlyargs = args.posonlyargs
    regular_args = args.args
    defaults = args.defaults

    # Align defaults with the end of args list
    all_positional = posonlyargs + regular_args
    num_no_default = len(all_positional) - len(defaults)

    for i, arg in enumerate(all_positional):
        formatted = _format_arg(arg)
        default_idx = i - num_no_default
        if default_idx >= 0:
            formatted += f" = {_unparse(defaults[default_idx])}"
        parts.append(formatted)
        # Insert / after positional-only args
        if posonlyargs and i == len(posonlyargs) - 1:
            parts.append("/")

    # *args or bare *
    if args.vararg:
        parts.append(f"*{_format_arg(args.vararg)}")
    elif args.kwonlyargs:
        parts.append("*")

    # keyword-only args
    for i, arg in enumerate(args.kwonlyargs):
        formatted = _format_arg(arg)
        if i < len(args.kw_defaults) and args.kw_defaults[i] is not None:
            formatted += f" = {_unparse(args.kw_defaults[i])}"
        parts.append(formatted)

    # **kwargs
    if args.kwarg:
        parts.append(f"**{_format_arg(args.kwarg)}")

    return ", ".join(parts)


def _format_decorator(node: ast.expr) -> str:
    """Format a decorator expression."""
    return f"@{_unparse(node)}"


def _slots_to_attrs(node: ast.ClassDef) -> list[str]:
    """Extract __slots__ names from a class definition."""
    for item in ast.iter_child_nodes(node):
        if isinstance(item, ast.Assign):
            for target in item.targets:
                is_slots = isinstance(target, ast.Name) and target.id == "__slots__"
                if is_slots and isinstance(item.value, (ast.Tuple, ast.List)):
                    return [
                        _unparse(elt)
                        for elt in item.value.elts
                        if isinstance(elt, ast.Constant) and isinstance(elt.value, str)
                    ]
    return []


def _generate_function(
    node: ast.FunctionDef | ast.AsyncFunctionDef, indent: str
) -> list[str]:
    """Generate stub lines for a function or method."""
    lines: list[str] = []
    prefix = "async def" if isinstance(node, ast.AsyncFunctionDef) else "def"

    for dec in node.decorator_list:
        lines.append(f"{indent}{_format_decorator(dec)}")

    args_str = _format_arguments(node.args)
    ret = f" -> {_unparse(node.returns)}" if node.returns else ""

    lines.append(f"{indent}{prefix} {node.name}({args_str}){ret}: ...")
    return lines


def _generate_class(node: ast.ClassDef, indent: str) -> list[str]:
    """Generate stub lines for a class definition."""
    lines: list[str] = []

    for dec in node.decorator_list:
        lines.append(f"{indent}{_format_decorator(dec)}")

    bases = ", ".join(_unparse(b) for b in node.bases)
    keywords = ", ".join(
        f"{kw.arg}={_unparse(kw.value)}" if kw.arg else f"**{_unparse(kw.value)}"
        for kw in node.keywords
    )
    all_bases = ", ".join(filter(None, [bases, keywords]))
    class_line = f"{indent}class {node.name}({all_bases}):" if all_bases else f"{indent}class {node.name}:"

    lines.append(class_line)

    body_lines: list[str] = []
    child_indent = indent + "    "

    # __slots__ become instance attributes
    slot_names = _slots_to_attrs(node)
    for name in slot_names:
        body_lines.append(f"{child_indent}{name}: Any")

    # Class body
    for item in node.body:
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
            body_lines.extend(_generate_function(item, child_indent))
        elif isinstance(item, ast.AnnAssign) and item.target:
            target = _unparse(item.target)
            ann = _unparse(item.annotation)
            if item.value is not None:
                body_lines.append(f"{child_indent}{target}: {ann} = {_unparse(item.value)}")
            else:
                body_lines.append(f"{child_indent}{target}: {ann}")
        elif isinstance(item, ast.Assign):
            for target in item.targets:
                name = _unparse(target)
                if name == "__slots__":
                    continue
                if isinstance(item.value, ast.Constant):
                    val = _unparse(item.value)
                    body_lines.append(f"{child_indent}{name} = {val}")
                else:
                    body_lines.append(f"{child_indent}{name}: Any")
        elif isinstance(item, ast.ClassDef):
            body_lines.extend(_generate_class(item, child_indent))

    if not body_lines:
        body_lines.append(f"{child_indent}...")

    lines.extend(body_lines)
    return lines


def _generate_stub(source: str) -> str:
    """Generate .pyi stub content from Python source code."""
    tree = ast.parse(source)
    lines: list[str] = []
    need_any = False

    for node in ast.iter_child_nodes(tree):
        # Imports
        if isinstance(node, ast.Import):
            # noinspection PyUnresolvedReferences
            names = ", ".join(
                f"{alias.name} as {alias.asname}" if alias.asname else alias.name
                for alias in node.names
            )
            lines.append(f"import {names}")

        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            names = ", ".join(
                f"{alias.name} as {alias.asname}" if alias.asname else alias.name
                for alias in node.names
            )
            dots = "." * (node.level or 0)
            lines.append(f"from {dots}{module} import {names}")

        # Functions
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            lines.append("")
            lines.extend(_generate_function(node, ""))

        # Classes
        elif isinstance(node, ast.ClassDef):
            lines.append("")
            stub_lines = _generate_class(node, "")
            if any(": Any" in l for l in stub_lines):
                need_any = True
            lines.extend(stub_lines)

        # Annotated assignments (module-level)
        elif isinstance(node, ast.AnnAssign) and node.target:
            target = _unparse(node.target)
            ann = _unparse(node.annotation)
            if node.value is not None:
                lines.append(f"{target}: {ann} = {_unparse(node.value)}")
            else:
                lines.append(f"{target}: {ann}")

        # Plain assignments (module-level constants like __all__, __version__)
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                name = _unparse(target)
                if isinstance(node.value, (ast.Constant, ast.List, ast.Tuple)):
                    lines.append(f"{name} = {_unparse(node.value)}")
                else:
                    lines.append(f"{name}: Any")
                    need_any = True

        # Type aliases (Python 3.12+)
        elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
            # Skip module-level docstrings
            pass

    # Prepend 'from typing import Any' if needed and not already imported
    result = "\n".join(lines)
    if need_any and "import Any" not in result:
        result = "from typing import Any\n" + result

    # Ensure trailing newline
    if result and not result.endswith("\n"):
        result += "\n"

    return result


def generate_stubs(vendor_dir: Path, out_dir: Path) -> None:
    """Walk vendor packages and generate .pyi stubs into out_dir."""
    if not vendor_dir.is_dir():
        print(f"Error: vendor directory not found: {vendor_dir}", file=sys.stderr)
        sys.exit(1)

    packages_found = 0

    for pkg_dir in sorted(vendor_dir.iterdir()):
        if not pkg_dir.is_dir():
            continue
        init_file = pkg_dir / "__init__.py"
        if not init_file.exists():
            continue

        pkg_name = pkg_dir.name
        stub_pkg_dir = out_dir / pkg_name
        stub_pkg_dir.mkdir(parents=True, exist_ok=True)

        py_count = 0
        for py_file in sorted(pkg_dir.glob("*.py")):
            try:
                source = py_file.read_text(encoding="utf-8")
                stub = _generate_stub(source)
                pyi_file = stub_pkg_dir / (py_file.stem + ".pyi")
                pyi_file.write_text(stub, encoding="utf-8")
                py_count += 1
            except SyntaxError as e:
                print(f"  Warning: syntax error in {py_file}: {e}", file=sys.stderr)

        if py_count:
            packages_found += 1
            print(f"  {pkg_name}/  ({py_count} stubs)")

    if packages_found == 0:
        print("Warning: no vendor packages found.", file=sys.stderr)
    else:
        print(f"\nDone: {packages_found} packages.", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <vendor_dir> <out_dir>", file=sys.stderr)
        sys.exit(1)

    vendor = Path(sys.argv[1])
    out = Path(sys.argv[2])

    generate_stubs(vendor, out)
