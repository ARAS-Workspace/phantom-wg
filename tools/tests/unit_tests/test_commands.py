"""Discovery, dispatch, arguments and the help text of core/commands.py."""

from __future__ import annotations

import pytest

from core.commands import discover, dispatch
from core.runner import ToolError

ENTRY = "./t.sh"
PLAIN = """
ABOUT = "Plain command"


def run():
    print("ran plain")
"""
WITH_ARGUMENTS = """
from core.commands import FORCE, argument

ABOUT = "With arguments"
ARGUMENTS = (FORCE, argument("service", nargs="?"))
USAGE = "args [-f] [service]"


def run(force, service):
    print("ran args", force, service)
"""
PASSTHROUGH = """
ABOUT = "As they came"
PASSTHROUGH = True


def run(args):
    print("ran through", list(args))
"""


@pytest.fixture
def stack(flows):
    flows.add("one", "plain", PLAIN)
    flows.add("two", "args", WITH_ARGUMENTS)
    flows.add("two", "through", PASSTHROUGH)
    return flows.package


def test_a_directory_is_a_command(flows):
    flows.add("setup", "gen_keys", PLAIN)
    (command,) = discover(flows.package)
    assert command.name == "gen-keys"
    assert command.group == "Setup"
    assert command.about == "Plain command"


def test_commands_come_in_the_order_of_their_paths(flows):
    flows.add("b", "second", PLAIN)
    flows.add("a", "zeta", PLAIN)
    flows.add("a", "alpha", PLAIN)
    assert [command.name for command in discover(flows.package)] == ["alpha", "zeta", "second"]


def test_a_file_beside_command_py_is_no_command(flows):
    flows.add("one", "plain", PLAIN)
    flows.add("one", "plain", "VALUE = 1\n", file="script.py")
    assert [command.name for command in discover(flows.package)] == ["plain"]


def test_a_directory_without_command_py_is_no_command(flows):
    flows.add("one", "plain", PLAIN)
    flows.add("one", "empty", "VALUE = 1\n", file="notes.py")
    assert [command.name for command in discover(flows.package)] == ["plain"]


def test_every_command_loads_at_the_start(flows, capsys):
    flows.add("one", "plain", PLAIN)
    flows.add("one", "loud", 'ABOUT = "x"\nprint("loaded")\n\n\ndef run():\n    pass\n')
    dispatch(ENTRY, flows.package, ["plain"])
    assert capsys.readouterr().out.splitlines() == ["loaded", "ran plain"]


@pytest.mark.parametrize(
    ("source", "error"),
    [
        ("def broken(:\n", SyntaxError),
        ('ABOUT = "No run"\n', AttributeError),
        ("def run():\n    pass\n", AttributeError),
        ("import no_such_module\n", ImportError),
    ],
)
def test_a_command_that_does_not_load_stops_the_tool(flows, source, error):
    flows.add("one", "plain", PLAIN)
    flows.add("one", "broken", source)
    with pytest.raises(error):
        dispatch(ENTRY, flows.package, ["plain"])


@pytest.mark.parametrize("argv", [[], ["help"], ["-h"], ["--help"]])
def test_help_names(stack, capsys, argv):
    dispatch(ENTRY, stack, argv)
    assert capsys.readouterr().out.startswith("Usage: ./t.sh <command>")


def test_help_comes_from_the_commands(stack, capsys):
    dispatch(ENTRY, stack, ["help"])
    out = capsys.readouterr().out
    for text in ("One:", "Two:", "plain", "Plain command", "args", "help", "See: ./t.sh help <command>"):
        assert text in out
    assert out.count("Two:") == 1
    assert "[service]" not in out
    assert "    through  As they came\n" in out


def test_the_longest_name_sets_the_column_of_the_help(flows, capsys):
    flows.add("one", "plain", PLAIN)
    flows.add("two", "a_name_longer_than_the_column_of_any_other", PLAIN)
    dispatch(ENTRY, flows.package, ["help"])
    out = capsys.readouterr().out
    abouts = ("Plain command", "Show this help")
    assert len({line.index(about) for line in out.splitlines() for about in abouts if about in line}) == 1
    assert "any-other  Plain command\n" in out


@pytest.mark.parametrize(
    "argv",
    [
        ["help", "args"],
        ["-h", "args"],
        ["--help", "args"],
        ["args", "--help"],
        ["args", "-h"],
        ["args", "-f", "--help"],
    ],
)
def test_a_command_shows_its_usage_and_does_not_run(stack, capsys, argv):
    dispatch(ENTRY, stack, argv)
    assert capsys.readouterr().out == "Usage: ./t.sh args [-f] [service]\n\n  With arguments\n"


def test_a_command_without_a_usage_shows_its_name(stack, capsys):
    dispatch(ENTRY, stack, ["help", "plain"])
    assert capsys.readouterr().out == "Usage: ./t.sh plain\n\n  Plain command\n"


def test_help_of_help_is_the_help(stack, capsys):
    dispatch(ENTRY, stack, ["help", "help"])
    assert capsys.readouterr().out.startswith("Usage: ./t.sh <command>")


def test_help_of_an_unknown_command_stops(stack):
    with pytest.raises(ToolError) as caught:
        dispatch(ENTRY, stack, ["help", "nope"])
    assert caught.value.code == 1
    assert str(caught.value) == "Unknown command: nope\nSee: ./t.sh help"


def test_help_takes_one_command(stack):
    with pytest.raises(ToolError) as caught:
        dispatch(ENTRY, stack, ["help", "plain", "args"])
    assert caught.value.code == 1
    assert str(caught.value) == "Usage: ./t.sh help [command]"


def test_help_shows_a_passthrough_command(stack, capsys):
    dispatch(ENTRY, stack, ["help", "through"])
    assert capsys.readouterr().out == "Usage: ./t.sh through\n\n  As they came\n"


def test_passthrough_takes_help_as_it_came(stack, capsys):
    dispatch(ENTRY, stack, ["through", "--help"])
    assert capsys.readouterr().out == "ran through ['--help']\n"


def test_unknown_command_stops(stack):
    with pytest.raises(ToolError) as caught:
        dispatch(ENTRY, stack, ["nope"])
    assert caught.value.code == 1
    assert str(caught.value) == "Unknown command: nope\nSee: ./t.sh help"


def test_a_command_without_arguments_takes_none(stack, capsys):
    dispatch(ENTRY, stack, ["plain"])
    assert capsys.readouterr().out == "ran plain\n"


def test_arguments_reach_the_command_as_parameters(stack, capsys):
    dispatch(ENTRY, stack, ["args", "-f", "nginx"])
    assert capsys.readouterr().out == "ran args True nginx\n"


def test_passthrough_takes_the_arguments_as_they_came(stack, capsys):
    dispatch(ENTRY, stack, ["through", "-k", "name", "--no-cleanup"])
    assert capsys.readouterr().out == "ran through ['-k', 'name', '--no-cleanup']\n"


@pytest.mark.parametrize(
    ("argv", "usage"),
    [
        (["plain", "--foo"], "plain"),
        (["args", "--forc"], "args [-f] [service]"),
        (["args", "a", "b"], "args [-f] [service]"),
    ],
)
def test_bad_arguments_stop_with_the_usage(stack, capfd, argv, usage):
    with pytest.raises(ToolError) as caught:
        dispatch(ENTRY, stack, argv)
    assert caught.value.code == 1
    assert str(caught.value) == f"Usage: ./t.sh {usage}"
    captured = capfd.readouterr()
    assert captured.out == ""
    assert captured.err == ""
