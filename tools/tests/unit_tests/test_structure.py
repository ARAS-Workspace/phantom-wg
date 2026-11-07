"""The rules of the code itself, read from the source."""

from __future__ import annotations

import ast
from pathlib import Path

import pytest
from support import TOOLCHAIN, run

HEADER_LINES = 11
SKIPPED = {".venv", ".idea", "__pycache__", "tests", "helper"}
LOCAL_ONLY = {".venv", ".idea", ".ruff_cache", ".pytest_cache", "__pycache__", ".DS_Store"}
MODULES = sorted(
    path.relative_to(TOOLCHAIN)
    for path in TOOLCHAIN.rglob("*.py")
    if not SKIPPED & set(path.relative_to(TOOLCHAIN).parts)
)
COMMANDS = [path for path in MODULES if path.parts[2:3] == ("flows",) and path.name == "command.py"]

# Each of these behaves differently between the floor and the peak of Python.
VERSION_SENSITIVE_ATTRIBUTES = {"utcnow", "getdefaultlocale", "file_digest", "walk"}
VERSION_SENSITIVE_KEYWORDS = {"onerror", "onexc", "slots", "kw_only", "strict"}


def parsed(relative: Path) -> ast.Module:
    return ast.parse((TOOLCHAIN / relative).read_text(encoding="utf-8"))


def imports(tree: ast.AST) -> set[str]:
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            found.add(node.module or "")
    return found


def touches(found: set[str], *names: str) -> set[str]:
    return {module for module in found for name in names if module == name or module.startswith(f"{name}.")}


def test_git_sees_every_file_of_the_tool():
    done = run(["git", "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "."], cwd=TOOLCHAIN)
    assert done.returncode == 0, done.stderr
    assert not [line for line in done.stdout.splitlines() if not LOCAL_ONLY & set(Path(line).parts)]


def test_modules_are_found():
    assert Path("core/runner.py") in MODULES
    assert Path("stack/dev/entry.py") in MODULES
    assert Path("stack/prod/entry.py") in MODULES
    assert len(COMMANDS) >= 32


@pytest.mark.parametrize("relative", MODULES, ids=str)
def test_header_and_ascii_body(relative):
    reference = (TOOLCHAIN / "__main__.py").read_text(encoding="utf-8").splitlines()[:HEADER_LINES]
    lines = (TOOLCHAIN / relative).read_text(encoding="utf-8").splitlines()
    assert lines[:HEADER_LINES] == reference
    assert "\n".join(lines[HEADER_LINES:]).isascii()


@pytest.mark.parametrize("relative", MODULES, ids=str)
def test_the_core_knows_no_stack(relative):
    if relative.parts[0] == "core":
        assert not touches(imports(parsed(relative)), "stack")


@pytest.mark.parametrize("relative", MODULES, ids=str)
def test_dev_and_prod_stay_apart(relative):
    found = imports(parsed(relative))
    if relative.parts[:2] == ("stack", "dev"):
        assert not touches(found, "stack.prod")
    if relative.parts[:2] == ("stack", "prod"):
        assert not touches(found, "stack.dev")


@pytest.mark.parametrize("relative", MODULES, ids=str)
def test_libs_know_no_flow(relative):
    if relative.parts[2:3] == ("libs",):
        assert not touches(imports(parsed(relative)), "stack.dev.flows", "stack.prod.flows")


@pytest.mark.parametrize("relative", MODULES, ids=str)
def test_a_command_stays_in_its_own_directory(relative):
    if relative.parts[2:3] == ("flows",):
        own = ".".join(relative.parts[:5])
        others = {module for module in touches(imports(parsed(relative)), "stack.dev.flows", "stack.prod.flows")}
        assert not {module for module in others if not module.startswith(own)}


@pytest.mark.parametrize("relative", MODULES, ids=str)
def test_subprocess_stays_in_the_runner(relative):
    if str(relative) != "core/runner.py":
        assert "subprocess" not in imports(parsed(relative))


@pytest.mark.parametrize("relative", MODULES, ids=str)
def test_modules_load_at_the_start(relative):
    functions = [
        node for node in ast.walk(parsed(relative))
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    ]
    assert not [function.name for function in functions if imports(function)]


@pytest.mark.parametrize("relative", MODULES, ids=str)
def test_no_version_sensitive_construct(relative):
    for node in ast.walk(parsed(relative)):
        if isinstance(node, ast.Attribute):
            assert node.attr not in VERSION_SENSITIVE_ATTRIBUTES
        if isinstance(node, ast.keyword):
            assert node.arg not in VERSION_SENSITIVE_KEYWORDS
        if isinstance(node, ast.ClassDef):
            bases = {base.id for base in node.bases if isinstance(base, ast.Name)}
            assert not {"str", "int"} & bases or "Enum" not in bases


@pytest.mark.parametrize("relative", COMMANDS, ids=str)
def test_a_command_holds_about_and_run(relative):
    body = parsed(relative).body
    names = {
        target.id
        for node in body
        if isinstance(node, ast.Assign)
        for target in node.targets
        if isinstance(target, ast.Name)
    }
    functions = {node.name for node in body if isinstance(node, ast.FunctionDef)}
    assert "ABOUT" in names
    assert "run" in functions


@pytest.mark.parametrize("name", ["prod.sh", "dev.sh"])
def test_entry_scripts_only_start_python(name):
    text = (TOOLCHAIN / name).read_text(encoding="utf-8")
    stack = name.split(".")[0]
    assert f'exec python3 -I -B -u "$TOOLCHAIN_DIR" {stack} "$@"\n' in text
    assert text.count("exec ") == 1
    assert "docker" not in text
