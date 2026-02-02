#!/opt/phantom-wg/.phantom-venv/bin/python3
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

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


def run_tests_with_coverage():
    """Run tests with coverage and generate reports"""

    # Fixed paths for /opt/phantom-wg environment
    tests_dir = Path("/opt/phantom-wg/phantom/bin/tests")
    integration_dir = tests_dir / "integration"
    reports_dir = tests_dir / "reports"
    html_test_reports_dir = reports_dir / "html_test_reports"

    logger.info("Starting coverage test execution")
    logger.info(f"Test directory: {tests_dir}")
    logger.info(f"Reports directory: {reports_dir}")

    # Create reports directory if it doesn't exist
    reports_dir.mkdir(exist_ok=True)
    html_test_reports_dir.mkdir(exist_ok=True)
    logger.info("Reports directories created/verified")

    # Set environment variables for coverage
    env = os.environ.copy()
    env['COVERAGE_FILE'] = str(tests_dir / '.coverage')

    # Check if integration tests exist
    python_path = "/opt/phantom-wg/.phantom-venv/bin/python"

    if integration_dir.exists():
        logger.info("Running integration tests with coverage collection")

        # HTML test report path for integration tests
        html_test_report = html_test_reports_dir / "integration_test_report.html"

        # Run integration tests with coverage
        cmd = [
            python_path, '-m', 'coverage', 'run',
            '--rcfile', str(tests_dir / '.coveragerc'),
            '-m', 'pytest',
            str(integration_dir),
            '-v',
            '--html', str(html_test_report),
            '--self-contained-html'
        ]

        result = subprocess.run(cmd, env=env)
    else:
        logger.info("Running all tests with coverage collection")

        # HTML test report path for all tests
        html_test_report = html_test_reports_dir / "all_tests_report.html"

        # Run all tests with coverage
        cmd = [
            python_path, '-m', 'coverage', 'run',
            '--rcfile', str(tests_dir / '.coveragerc'),
            '-m', 'pytest',
            str(tests_dir),
            '-v',
            '--html', str(html_test_report),
            '--self-contained-html'
        ]

        result = subprocess.run(cmd, env=env)

    if result.returncode != 0:
        logger.error(f"Test execution failed with return code: {result.returncode}")
        return result.returncode

    logger.info("Test execution completed successfully")
    logger.info("Generating coverage reports")

    # Generate HTML report
    logger.info("Generating HTML report")
    subprocess.run([
        python_path, '-m', 'coverage', 'html',
        '--rcfile', str(tests_dir / '.coveragerc'),
        '-d', str(reports_dir / 'htmlcov')
    ], env=env)

    # Generate XML report
    logger.info("Generating XML report")
    subprocess.run([
        python_path, '-m', 'coverage', 'xml',
        '--rcfile', str(tests_dir / '.coveragerc'),
        '-o', str(reports_dir / 'coverage.xml')
    ], env=env)

    # Generate JSON report
    logger.info("Generating JSON report")
    subprocess.run([
        python_path, '-m', 'coverage', 'json',
        '--rcfile', str(tests_dir / '.coveragerc'),
        '-o', str(reports_dir / 'coverage.json')
    ], env=env)

    # Show coverage summary
    logger.info("Coverage summary:")
    subprocess.run([
        python_path, '-m', 'coverage', 'report',
        '--rcfile', str(tests_dir / '.coveragerc')
    ], env=env)

    logger.info("Coverage report generation completed")
    logger.info(f"HTML coverage report: {reports_dir}/htmlcov/index.html")
    logger.info(f"HTML test report: {html_test_report}")
    logger.info(f"XML report: {reports_dir}/coverage.xml")
    logger.info(f"JSON report: {reports_dir}/coverage.json")

    return 0


if __name__ == "__main__":
    sys.exit(run_tests_with_coverage())
