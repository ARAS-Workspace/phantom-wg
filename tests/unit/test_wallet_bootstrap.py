"""Tests for the wallet bootstrap tools/prod.sh runs at setup."""

from __future__ import annotations

from phantom_daemon.base.wallet import open_wallet
from phantom_daemon.base.wallet.bootstrap import main


def subnet_of(db_dir) -> str:
    with open_wallet(str(db_dir)) as wallet:
        return wallet.get_config("ipv4_subnet")


class TestBootstrap:
    def test_creates_the_pool_of_a_subnet(self, tmp_path, capsys):
        assert main(["bootstrap", str(tmp_path), "10.9.0.0/24"]) == 0
        assert subnet_of(tmp_path) == "10.9.0.0/24"
        assert "Pool: 10.9.0.0/24" in capsys.readouterr().out

    def test_takes_the_default_subnet(self, tmp_path):
        assert main(["bootstrap", str(tmp_path)]) == 0
        assert subnet_of(tmp_path) == "10.8.0.0/24"

    def test_an_existing_wallet_keeps_its_pool(self, tmp_path, capsys):
        assert main(["bootstrap", str(tmp_path), "10.9.0.0/24"]) == 0
        assert main(["bootstrap", str(tmp_path), "10.10.0.0/24"]) == 1
        assert subnet_of(tmp_path) == "10.9.0.0/24"
        assert "already exists" in capsys.readouterr().err

    def test_takes_a_directory_and_a_subnet_at_most(self, tmp_path):
        assert main(["bootstrap"]) == 2
        assert main(["bootstrap", str(tmp_path), "10.9.0.0/24", "extra"]) == 2
