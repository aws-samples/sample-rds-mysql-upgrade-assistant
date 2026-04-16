"""Unit tests for MCP tool wrappers."""

import json
import subprocess
from unittest.mock import patch, MagicMock
from pathlib import Path

import pytest

# We test the _run helper and tool argument construction
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "src"))

from rds_upgrade_mcp.tools import _run, SCRIPTS_DIR


class TestRunHelper:
    def test_run_returns_parsed_json(self):
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = '[{"instance_id": "test"}]'

        with patch("subprocess.run", return_value=mock_result) as mock_sub:
            result = _run("inventory/discover_instances.sh", ["--json"])
            assert result == [{"instance_id": "test"}]
            mock_sub.assert_called_once()

    def test_run_raises_on_nonzero_exit(self):
        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stderr = "ERROR: something failed"
        mock_result.stdout = ""

        with patch("subprocess.run", return_value=mock_result):
            with pytest.raises(RuntimeError, match="failed"):
                _run("inventory/discover_instances.sh", ["--json"])

    def test_run_raises_on_invalid_json(self):
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "not json"

        with patch("subprocess.run", return_value=mock_result):
            with pytest.raises(json.JSONDecodeError):
                _run("inventory/discover_instances.sh", ["--json"])

    def test_run_constructs_correct_command(self):
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "[]"

        with patch("subprocess.run", return_value=mock_result) as mock_sub:
            _run("inventory/discover_instances.sh", ["--json", "--region", "us-east-1"])
            cmd = mock_sub.call_args[0][0]
            assert cmd[0] == "bash"
            assert "discover_instances.sh" in cmd[1]
            assert "--json" in cmd
            assert "--region" in cmd
            assert "us-east-1" in cmd

    def test_run_passes_timeout(self):
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "{}"

        with patch("subprocess.run", return_value=mock_result) as mock_sub:
            _run("precheck/mysql_precheck_run.sh", ["-h", "test"], timeout=600)
            assert mock_sub.call_args[1]["timeout"] == 600


class TestScriptsDir:
    def test_scripts_dir_exists(self):
        assert SCRIPTS_DIR.exists()

    def test_scripts_dir_has_expected_subdirs(self):
        expected = ["precheck", "inventory", "upgrade", "validate", "batch"]
        for subdir in expected:
            assert (SCRIPTS_DIR / subdir).exists(), f"Missing: scripts/{subdir}"
