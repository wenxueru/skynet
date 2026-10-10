#!/usr/bin/env python3
"""Check staged files or reachable Git history without printing sensitive values."""
import re
import subprocess
import sys


def git(*args):
    return subprocess.check_output(['git', *args])


private_files = {
    'AGENTS.md', 'history.cmt', 'commit.tmp',
    'docs/status.md', 'docs/basic_function_verification.md',
    'docs/project_memory_reference.md',
    'Apps/macOS/Tests/SessionExportAudit.swift',
    'Apps/macOS/Tests/TranscriptToolProvenanceAudit.swift',
    'Apps/macOS/Tests/run-transcript-tool-provenance-audit.sh',
}
home = re.compile(rb'/(?:Users|home)/([A-Za-z0-9_.-]+)')
email = re.compile(rb'\b[A-Za-z0-9_.+%-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b')
secrets = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{35,}|AKIA[A-Z0-9]{16}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,})\b')
tool_ids = re.compile(rb'\b(?:call_[A-Za-z0-9_-]{20,}|exec-[a-f0-9-]{36})\b', re.I)
failures = set()


def check(data, path):
    if path in private_files or path.startswith('docs/archive/'):
        failures.add((path, 'private local-only file'))
    if any(m[1].lower() not in {b'example', b'test', b'me', b'user'} for m in home.finditer(data)):
        failures.add((path, 'non-example home path'))
    if any(m[1].lower() not in {b'example.com', b'example.org', b'example.net', b'users.noreply.github.com'} for m in email.finditer(data)):
        failures.add((path, 'non-example email'))
    if secrets.search(data):
        failures.add((path, 'credential-shaped literal'))
    if tool_ids.search(data):
        failures.add((path, 'captured tool-call identifier; use synthetic fixtures'))


objects = {}
if sys.argv[1:] == ['--staged']:
    for row in git('ls-files', '--stage', '-z').split(b'\0'):
        if row:
            meta, path = row.split(b'\t', 1)
            objects[meta.split()[1]] = path.decode()
elif not sys.argv[1:]:
    for row in git('rev-list', '--objects', '--all').splitlines():
        oid, _, path = row.partition(b' ')
        objects[oid] = path.decode(errors='replace') or '(commit metadata)'
else:
    sys.exit('Usage: python3 scripts/check-privacy.py [--staged]')

process = subprocess.Popen(['git', 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
for oid, path in objects.items():
    process.stdin.write(oid + b'\n')
    process.stdin.flush()
    header = process.stdout.readline().split()
    data = process.stdout.read(int(header[2]))
    process.stdout.read(1)
    if header[1] in (b'blob', b'commit', b'tag'):
        check(data, path)
process.stdin.close()
if process.wait():
    sys.exit('Git object inspection failed')
for path, reason in sorted(failures):
    print(f'FAIL: {path}: {reason}')
if failures:
    sys.exit(1)
print(f'PASS: privacy checks for {len(objects)} Git objects')
