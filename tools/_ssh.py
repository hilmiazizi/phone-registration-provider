#!/usr/bin/env python3
"""Tiny SSH runner for PoC iPhones. Usage:
   BEEPSERV_SSH_HOST=192.168.x.x BEEPSERV_SSH_PASS=... \\
     python3 _ssh.py 'command'           # run as mobile
   python3 _ssh.py --sudo 'command'      # run via sudo (uses BEEPSERV_SUDO_PASS)
"""
import os
import sys
import paramiko

HOST = os.environ.get("BEEPSERV_SSH_HOST", "192.168.18.153")
USER = os.environ.get("BEEPSERV_SSH_USER", "mobile")
PASS = os.environ.get("BEEPSERV_SSH_PASS", "")
SUDO_PASS = os.environ.get("BEEPSERV_SUDO_PASS", PASS)


def run(cmd, sudo=False, timeout=120):
    if not PASS:
        raise SystemExit("Set BEEPSERV_SSH_PASS (and optionally BEEPSERV_SSH_HOST)")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15,
              allow_agent=False, look_for_keys=False)
    if sudo:
        cmd = f"echo {SUDO_PASS} | sudo -S -p '' bash -lc {shq(cmd)}"
    stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    rc = stdout.channel.recv_exit_status()
    c.close()
    return rc, out, err


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def _client():
    if not PASS:
        raise SystemExit("Set BEEPSERV_SSH_PASS (and optionally BEEPSERV_SSH_HOST)")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15,
              allow_agent=False, look_for_keys=False)
    return c


def get(remote, local):
    """SFTP pull a file (must be readable by USER)."""
    c = _client()
    sftp = c.open_sftp()
    sftp.get(remote, local)
    sftp.close(); c.close()


def put(local, remote):
    c = _client()
    sftp = c.open_sftp()
    sftp.put(local, remote)
    sftp.close(); c.close()


if __name__ == "__main__":
    args = sys.argv[1:]
    sudo = False
    if args and args[0] == "--sudo":
        sudo = True
        args = args[1:]
    cmd = args[0] if args else "echo CONNECTED; id; uname -a"
    rc, out, err = run(cmd, sudo=sudo)
    sys.stdout.write(out)
    if err:
        sys.stderr.write("[stderr]\n" + err)
    sys.exit(rc)
