"""Shared test fixtures."""

import pytest
from pathlib import Path

@pytest.fixture
def project_root():
    return Path(__file__).resolve().parent.parent

@pytest.fixture
def scripts_dir(project_root):
    return project_root / "scripts"
