"""The call kinds of core/runner.py and their rules."""

from __future__ import annotations

import os
import signal
import subprocess
import textwrap

import pytest
from support import TIMEOUT, python_lines, run

from core.runner import Answer, ToolError, capture, probe, stream

FRAME = """
from pathlib import Path
from core import runner
from core.runner import ToolError, capture, replace, stream

runner.ROOT = Path(sys.argv[1])
"""


def framed(code: str, root) -> list[str]:
    """A command that runs code with the root at root."""
    return [*python_lines(FRAME + textwrap.dedent(code)), str(root)]


def in_process(code: str, root, **options):
    """Runs code on its own stdio."""
    return run(framed(code, root), **options)


def test_stream_output_reaches_the_terminal(root, capfd):
    stream(["echo", "live"])
    assert capfd.readouterr().out == "live\n"


def test_stream_failure_keeps_the_exit_code(root):
    with pytest.raises(ToolError) as caught:
        stream(["sh", "-c", "exit 7"])
    assert caught.value.code == 7
    assert str(caught.value) == "sh -c exited 7"


def test_stream_missing_command_exits_127(root):
    with pytest.raises(ToolError) as caught:
        stream(["no-such-command"])
    assert caught.value.code == 127


def test_stream_starts_in_the_root(root, tmp_path_factory, monkeypatch):
    monkeypatch.chdir(tmp_path_factory.mktemp("elsewhere"))
    stream(["sh", "-c", "pwd -P > where"])
    assert (root / "where").read_text(encoding="utf-8").strip() == str(root)


def test_stream_cwd_is_relative_to_the_root(root):
    (root / "sub").mkdir()
    stream(["sh", "-c", "pwd -P > where"], cwd="sub")
    assert (root / "sub/where").read_text(encoding="utf-8").strip() == str(root / "sub")


def test_stream_env_adds_to_the_environment(root, capfd, monkeypatch):
    monkeypatch.setenv("KEPT", "kept")
    stream(["sh", "-c", "echo $ADDED $KEPT"], env={"ADDED": "added"})
    assert capfd.readouterr().out == "added kept\n"


def test_stream_signal_exits_as_a_shell_reports(root):
    with pytest.raises(ToolError) as caught:
        stream(["sh", "-c", "kill -TERM $$"])
    assert caught.value.code == 143


def test_ctrl_c_leaves_the_command_its_cleanup(tmp_path):
    code = """
    script = "trap 'kill $!; sleep 0.2; echo cleaned; exit 3' INT; sleep 5 & echo ready; wait"
    try:
        stream(["sh", "-c", script])
    except ToolError as error:
        print("code", error.code)
    """
    process = subprocess.Popen(
        framed(code, tmp_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        start_new_session=True,
    )
    assert process.stdout.readline().strip() == "ready"
    os.killpg(process.pid, signal.SIGINT)
    output = process.communicate(timeout=TIMEOUT)[0]
    assert "cleaned" in output
    assert "code 3" in output


def test_capture_returns_the_value_and_leaves_stderr(root, capfd):
    assert capture(["sh", "-c", "echo value; echo visible >&2"]) == "value"
    captured = capfd.readouterr()
    assert captured.out == ""
    assert captured.err == "visible\n"


def test_capture_failure_keeps_the_exit_code(root):
    with pytest.raises(ToolError) as caught:
        capture(["sh", "-c", "exit 5"])
    assert caught.value.code == 5


def test_capture_missing_command_exits_127(root):
    with pytest.raises(ToolError) as caught:
        capture(["no-such-command"])
    assert caught.value.code == 127


def test_capture_reads_utf8_under_any_locale(tmp_path):
    code = r'print([ord(c) for c in capture(["printf", "\\304\\261"])])'
    done = in_process(code, tmp_path, env={"PATH": "/usr/bin:/bin", "LC_ALL": "en_US.ISO8859-1"})
    assert done.stdout.strip() == "[305]", done.stderr


def test_capture_survives_bytes_that_are_not_utf8(root):
    assert capture(["printf", "\\377"]) == "�"


def test_probe_returns_the_answer_in_silence(root, capfd):
    answer = probe(["sh", "-c", "echo answer; echo hidden >&2"])
    assert answer == Answer(True, "answer")
    assert capfd.readouterr().err == ""


def test_probe_failure_is_an_answer(root, capfd):
    answer = probe(["sh", "-c", "echo hidden >&2; exit 4"])
    assert not answer.ok
    assert capfd.readouterr().err == ""


def test_probe_missing_command_is_an_answer(root):
    assert probe(["no-such-command"]) == Answer(False, "")


def test_replace_keeps_the_exit_code_and_starts_in_the_root(tmp_path):
    done = in_process('replace(["sh", "-c", "pwd -P; exit 9"])', tmp_path.resolve())
    assert done.returncode == 9
    assert done.stdout.strip() == str(tmp_path.resolve())


def test_replace_missing_command_exits_127(tmp_path):
    code = """
    try:
        replace(["no-such-command"])
    except ToolError as error:
        print(error.code)
    """
    assert in_process(code, tmp_path).stdout.strip() == "127"


def test_replace_gives_sigpipe_back(tmp_path):
    script = tmp_path / "yes.py"
    command = python_lines(FRAME + 'replace(["yes"])')
    script.write_text(command[-1], encoding="utf-8")
    line = f'"{command[0]}" -I -B -u "{script}" "{tmp_path}" | head -n 1; echo "status=${{PIPESTATUS[0]}}"'
    done = run(["bash", "-c", line])
    assert "status=141" in done.stdout
    assert done.stderr == ""
