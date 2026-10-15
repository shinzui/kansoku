"""Shared result auditing for executable acceptance; zero/pending is never success."""
from pathlib import Path
import os
import re
import signal
import subprocess


def binary(target):
    return subprocess.check_output(['cabal', 'list-bin', target], text=True).strip()


def execute(command, *, env=None, timeout=180, input=None):
    """A timeout/interruption must also stop children created by the test executable."""
    process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(input=input, timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=10)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise


def hspec(command, *, env=None, log=None, timeout=180):
    result = execute(command, env=env, timeout=timeout)
    output = result.stdout + result.stderr
    if log:
        Path(log).write_text(output)
    print(output, end='', flush=True)
    result.check_returncode()
    summary = re.search(r'(\d+) examples?, (\d+) failures(?:, (\d+) pending)?', output)
    if not summary or int(summary[1]) == 0 or summary[2] != '0' or int(summary[3] or 0) != 0:
        raise RuntimeError('required Hspec run has zero examples, failures, or pending cases')
    return int(summary[1])


def probes(command, *, env=None, log=None):
    result = execute(command, env=env, timeout=60)
    output = result.stdout + result.stderr
    if log:
        Path(log).write_text(output)
    print(output, end='', flush=True)
    result.check_returncode()
    summary = re.search(r'All (\d+) tests passed', output)
    if not summary or int(summary[1]) == 0:
        raise RuntimeError('required probe kit did not report nonzero passing cases')
