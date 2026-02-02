"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Simple Test Runner for Phantom-WG

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import os
import sys
import subprocess
import logging
from pathlib import Path
from collections import OrderedDict
from datetime import datetime
from textwrap import dedent

# ============================================================================
# CONFIGURATION
# ============================================================================

# Project paths
phantom_dir = Path(__file__).parent
project_root = phantom_dir.parent
sys.path.insert(0, str(project_root))
sys.path.insert(0, str(phantom_dir))

# Logger setup
logging.basicConfig(
    level=logging.INFO,
    format='%(levelname)-8s %(message)s'
)
logger = logging.getLogger(__name__)

# ============================================================================
# MODULE DEFINITIONS
# ============================================================================

# Module configurations with default test order
modules = OrderedDict([
    ("core", ("modules/core", "phantom.modules.core")),
    ("dns", ("modules/dns", "phantom.modules.dns")),
    ("multihop", ("modules/multihop", "phantom.modules.multihop")),
    ("ghost", ("modules/ghost", "phantom.modules.ghost")),
    ("models", ("models", "phantom.models")),
    ("api", ("api", "phantom.api")),
])

# ============================================================================
# DEFAULT VALUES
# ============================================================================

# Base reports directory
reports_base = phantom_dir / "reports" / "coverage"


def run_module_tests(mod_path, cov_name, session_dir):
    """Run tests for a module with coverage"""

    test_dir = phantom_dir / mod_path / "tests"
    if not test_dir.exists():
        logger.warning(f"No tests found at {test_dir}")
        return True

    logger.info("")
    logger.info(f"Module: {cov_name}")
    logger.info(f"Test directory: {test_dir}")

    # Create output directory for this module within session
    mod_name = mod_path.replace("/", "_")
    coverage_dir = session_dir / "coverage_reports" / mod_name
    coverage_dir.mkdir(parents=True, exist_ok=True)

    # Create HTML test reports directory
    html_reports_dir = coverage_dir / "html_test_reports"
    html_reports_dir.mkdir(parents=True, exist_ok=True)

    # Set up environment for coverage
    env = os.environ.copy()
    coverage_file = coverage_dir / f".coverage.{mod_name}"
    env['COVERAGE_FILE'] = str(coverage_file)

    # Check what subdirectories exist
    unit_dir = test_dir / "unit"
    integration_dir = test_dir / "integration"

    test_passed = True

    # Run unit tests first if they exist
    if unit_dir.exists() and any(unit_dir.glob("*.py")):
        logger.info(f"Running unit tests for {mod_name}...")

        # HTML report path for unit tests
        unit_html_report = html_reports_dir / "unit_test_report.html"

        unit_cmd = [
            sys.executable, "-m", "pytest",
            str(unit_dir),
            f"--cov={cov_name}",
            "--cov-append",
            f"--cov-config={session_dir}/.coveragerc",
            "--cov-report=",
            "-v",
            "--html", str(unit_html_report),
            "--self-contained-html"
        ]

        unit_result = subprocess.run(unit_cmd, cwd=project_root, env=env)

        if unit_result.returncode == 0:
            logger.info(f"Unit tests completed successfully for {mod_name}")
        else:
            logger.error(f"Unit tests failed for {mod_name}")
            test_passed = False

    # Run integration tests if they exist and unit tests passed
    if test_passed and integration_dir.exists() and any(integration_dir.glob("*.py")):
        logger.info(f"Running integration tests for {mod_name}...")

        # HTML report path for integration tests
        integration_html_report = html_reports_dir / "integration_test_report.html"

        # Check for docker tests
        docker_tests = list(integration_dir.glob("*_docker.py"))

        integration_cmd = [
            sys.executable, "-m", "pytest",
            str(integration_dir),
            f"--cov={cov_name}",
            "--cov-append",
            f"--cov-config={session_dir}/.coveragerc",
            "--cov-report=",
            "-v",
            "--html", str(integration_html_report),
            "--self-contained-html"
        ]

        if docker_tests:
            logger.info(f"Docker tests detected: {len(docker_tests)} file(s)")
            integration_cmd.append("--docker")

        integration_result = subprocess.run(integration_cmd, cwd=project_root, env=env)

        if integration_result.returncode == 0:
            logger.info(f"Integration tests completed successfully for {mod_name}")
        else:
            logger.error(f"Integration tests failed for {mod_name}")
            test_passed = False

    # If neither unit nor integration dirs exist, run all tests in test_dir
    if not unit_dir.exists() and not integration_dir.exists():
        logger.info(f"Running all tests for {mod_name}...")

        # HTML report path for all tests
        all_html_report = html_reports_dir / "all_tests_report.html"

        all_cmd = [
            sys.executable, "-m", "pytest",
            str(test_dir),
            f"--cov={cov_name}",
            "--cov-append",
            f"--cov-config={session_dir}/.coveragerc",
            "--cov-report=",
            "-v",
            "--html", str(all_html_report),
            "--self-contained-html"
        ]

        # Check for docker tests
        docker_tests = list(test_dir.rglob("*_docker.py"))
        if docker_tests:
            logger.info(f"Docker tests detected: {len(docker_tests)} file(s)")
            all_cmd.append("--docker")

        all_result = subprocess.run(all_cmd, cwd=project_root, env=env)
        test_passed = (all_result.returncode == 0)

    if test_passed:
        logger.info(f"All tests completed successfully for {mod_name}")
    else:
        logger.error(f"Tests failed for {mod_name}")

    # Check if coverage file was created
    if coverage_file.exists():
        logger.info(f"Coverage data saved: {coverage_file}")

        # Now generate reports for this module after tests are complete
        if test_passed:
            logger.info(f"Generating coverage reports for {mod_name}...")

            # Generate HTML report
            html_cmd = [
                sys.executable, "-m", "coverage", "html",
                "--data-file", str(coverage_file),
                "-d", str(coverage_dir / "htmlcov")
            ]
            subprocess.run(html_cmd, cwd=project_root, capture_output=True)

            # Generate XML report
            xml_cmd = [
                sys.executable, "-m", "coverage", "xml",
                "--data-file", str(coverage_file),
                "-o", str(coverage_dir / "coverage.xml")
            ]
            subprocess.run(xml_cmd, cwd=project_root, capture_output=True)

            # Generate JSON report
            json_cmd = [
                sys.executable, "-m", "coverage", "json",
                "--data-file", str(coverage_file),
                "-o", str(coverage_dir / "coverage.json")
            ]
            subprocess.run(json_cmd, cwd=project_root, capture_output=True)

            # Generate terminal report
            report_cmd = [
                sys.executable, "-m", "coverage", "report",
                "--data-file", str(coverage_file)
            ]
            subprocess.run(report_cmd, cwd=project_root)

            logger.info(f"Coverage reports generated for {mod_name}")

            # Log HTML test report location if exists
            if html_reports_dir.exists():
                html_files = list(html_reports_dir.glob("*.html"))
                if html_files:
                    logger.info(f"HTML test reports saved in: {html_reports_dir}")
                    for html_file in html_files:
                        logger.info(f"  - {html_file.name}")
    else:
        # Check for any .coverage files in the directory
        any_coverage = list(coverage_dir.glob(".coverage*"))
        if any_coverage:
            logger.info(f"Coverage files found: {any_coverage}")
        else:
            logger.warning(f"No coverage data found in {coverage_dir}")

    # Copy coverage data for full phantom coverage if tests passed
    if test_passed and coverage_file.exists():
        # Copy the coverage file for combined report (no need to run tests again)
        full_coverage_file = coverage_dir / f".coverage.{mod_name}_full"

        import shutil
        shutil.copy(coverage_file, full_coverage_file)

        logger.info(f"Coverage data copied for combined report: {full_coverage_file}")
    else:
        if not test_passed:
            logger.warning(f"Skipping coverage copy for {mod_name} due to test failure")
        else:
            logger.warning(f"No coverage file to copy for {mod_name}")

    return test_passed


def main(custom_session_id=None):
    """Run all module tests"""

    # Track start time
    import time
    start_time = time.time()

    # Use provided session ID or generate new one
    current_session = custom_session_id or datetime.now().strftime("%Y%m%d_%H%M%S")
    session_dir = reports_base / current_session
    session_dir.mkdir(parents=True, exist_ok=True)

    # Create .coveragerc file for this session
    coveragerc_content = dedent(f"""
        [run]
        data_file = {session_dir}/.coverage
        source = phantom
        omit =
            */tests/*

        [report]
        exclude_lines =
            pragma: no cover
            def __repr__
            raise AssertionError
            raise NotImplementedError
    """).strip()

    coveragerc_path = session_dir / ".coveragerc"
    coveragerc_path.write_text(coveragerc_content)

    test_modules = list(modules.values())
    module_names = list(modules.keys())

    logger.info("Phantom-WG Test Suite")
    logger.info(f"Base directory: {project_root}")
    logger.info(f"Session ID: {current_session}")
    logger.info(f"Session directory: {session_dir}")
    logger.info(f"Modules to test: {', '.join(module_names)}")
    logger.info("")

    failed_modules = []

    for mod_path, cov_name in test_modules:
        if not run_module_tests(mod_path, cov_name, session_dir):
            failed_modules.append(cov_name)

    # Generate combined coverage report
    logger.info("")
    logger.info("Generating combined coverage report...")
    combined_dir = session_dir / "combined_coverage"
    combined_dir.mkdir(exist_ok=True)

    # Collect full phantom coverage data files (with _full suffix)
    full_coverage_files = list(session_dir.glob("coverage_reports/*/.coverage*_full"))

    logger.info(f"Found {len(full_coverage_files)} full phantom coverage data files")

    if full_coverage_files:
        # Create a temporary .coveragerc for combining
        combine_rc = dedent(f"""
            [run]
            data_file = {combined_dir}/.coverage
            source = phantom
            omit =
                */tests/*
                phantom/run_tests_coverage.py
                phantom/bin/*
                phantom/cli/*
                phantom/scripts/*
                phantom/reports/*
        """).strip()

        combine_rc_path = combined_dir / ".coveragerc"
        combine_rc_path.write_text(combine_rc)

        # Combine all coverage data
        combine_cmd = [
            sys.executable, "-m", "coverage", "combine",
            "--rcfile", str(combine_rc_path),
            "--data-file", str(combined_dir / ".coverage"),
            *[str(f) for f in full_coverage_files]
        ]

        logger.info(f"Combining coverage data...")
        combine_result = subprocess.run(combine_cmd, cwd=project_root, capture_output=True, text=True)

        if combine_result.returncode == 0:
            # Generate combined reports
            coverage_data_file = str(combined_dir / ".coverage")
            report_commands = [
                ([sys.executable, "-m", "coverage", "html", "--rcfile", str(combine_rc_path), "--data-file",
                  coverage_data_file, "-d", str(combined_dir / "htmlcov")], "HTML"),
                ([sys.executable, "-m", "coverage", "xml", "--rcfile", str(combine_rc_path), "--data-file",
                  coverage_data_file, "-o", str(combined_dir / "coverage.xml")], "XML"),
                ([sys.executable, "-m", "coverage", "json", "--rcfile", str(combine_rc_path), "--data-file",
                  coverage_data_file, "-o", str(combined_dir / "coverage.json")], "JSON"),
            ]

            for cmd, format_name in report_commands:
                result = subprocess.run(cmd, cwd=project_root, capture_output=True, text=True)
                if result.returncode == 0:
                    logger.info(f"  Generated {format_name} report")
                else:
                    logger.warning(f"  Failed to generate {format_name} report: {result.stderr}")

            # Show total coverage
            report_cmd = [sys.executable, "-m", "coverage", "report", "--rcfile", str(combine_rc_path), "--data-file",
                          coverage_data_file, "--skip-covered"]
            report_result = subprocess.run(report_cmd, cwd=project_root, capture_output=True, text=True)

            if report_result.returncode == 0:
                # Extract total coverage percentage from the output
                lines = report_result.stdout.strip().split('\n')
                if lines and "TOTAL" in lines[-1]:
                    logger.info("")
                    logger.info(f"Combined coverage: {lines[-1]}")
        else:
            logger.warning("Could not combine coverage data")
            logger.warning(f"Error: {combine_result.stderr}")
    else:
        logger.warning("No coverage data files found to combine")

    # Calculate elapsed time
    end_time = time.time()
    elapsed_time = end_time - start_time

    # Format elapsed time
    hours, remainder = divmod(elapsed_time, 3600)
    minutes, seconds = divmod(remainder, 60)

    if hours > 0:
        time_str = f"{int(hours)}h {int(minutes)}m {int(seconds)}s"
    elif minutes > 0:
        time_str = f"{int(minutes)}m {int(seconds)}s"
    else:
        time_str = f"{elapsed_time:.2f}s"

    # Summary
    logger.info("")
    logger.info("Test Execution Summary")
    logger.info("-" * 25)

    total_modules = len(module_names)
    passed_modules = total_modules - len(failed_modules)

    logger.info(f"Total modules: {total_modules}")
    logger.info(f"Passed: {passed_modules}")
    logger.info(f"Failed: {len(failed_modules)}")
    logger.info(f"Execution time: {time_str}")

    if failed_modules:
        logger.info("")
        logger.error("Failed modules:")
        for module in failed_modules:
            logger.error(f"  - {module}")
        return 1
    else:
        logger.info("")
        logger.info("Result: All tests passed successfully")
        return 0


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Phantom Test Runner")
    parser.add_argument("--session-id", help="Custom session ID (default: timestamp)")

    args = parser.parse_args()

    sys.exit(main(custom_session_id=args.session_id))
