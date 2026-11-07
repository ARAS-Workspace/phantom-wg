"""From the flows of a stack to the exit code: core/app.py."""

from __future__ import annotations

import pytest

from core import app, runner


def raising(error: str) -> str:
    return f"""
    from core.runner import ToolError

    ABOUT = "Raises"


    def run():
        raise {error}
    """


def test_root_is_the_parent_of_the_toolchain():
    assert (runner.ROOT / "tools/core/app.py").is_file()


def test_tool_error_goes_to_stderr_with_its_code(flows, capsys):
    flows.add("one", "go", raising('ToolError("stopped", 7)'))
    with pytest.raises(SystemExit) as caught:
        app.run("./t.sh", flows.package, ["go"])
    assert caught.value.code == 7
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == "stopped\n"


@pytest.mark.parametrize(
    ("error", "code"),
    [("KeyboardInterrupt()", 130), ("BrokenPipeError()", 141)],
)
def test_interruptions_end_quietly(flows, capsys, error, code):
    flows.add("one", "go", raising(error))
    with pytest.raises(SystemExit) as caught:
        app.run("./t.sh", flows.package, ["go"])
    assert caught.value.code == code
    assert capsys.readouterr().err == ""


def test_an_operating_system_error_stops_without_a_traceback(flows, capsys):
    flows.add("one", "go", raising('PermissionError(13, "Permission denied", "/secret")'))
    with pytest.raises(SystemExit) as caught:
        app.run("./t.sh", flows.package, ["go"])
    assert caught.value.code == 1
    assert capsys.readouterr().err == "[Errno 13] Permission denied: '/secret'\n"


def test_a_defect_stays_a_traceback(flows):
    flows.add("one", "go", raising("ZeroDivisionError()"))
    with pytest.raises(ZeroDivisionError):
        app.run("./t.sh", flows.package, ["go"])
