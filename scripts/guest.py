#!/usr/bin/env python3
"""guest.py LOG CMDS -- QEMU...

Boots a qemu-system guest with its console on stdio, logs in as root, switches to /bin/sh and
runs each line of the file CMDS in turn. Each command's exit status is printed as
'GUEST <rc> <command>'. Lines starting with '-' may fail; any other failure stops the run.
Exits with the status of the last command run.
Env: BOOT_TIMEOUT (s, default 3600), CMD_TIMEOUT (s, default 21600)."""
import os
import re
import sys

import pexpect

log, cmds, qemu = sys.argv[1], sys.argv[2], sys.argv[4:]
boot_to = int(os.environ.get("BOOT_TIMEOUT", "3600"))
cmd_to = int(os.environ.get("CMD_TIMEOUT", "21600"))
PS = "GUESTPS> "

def boot():
    q = pexpect.spawn(qemu[0], qemu[1:], encoding="utf-8", codec_errors="replace", timeout=boot_to)
    q.logfile_read = open(log, "a")
    q.delaybeforesend = 0.05
    return q


# qemu runs with -no-reboot: a reboot (first-boot root resize, fsck) or a port whose reboot
# drops into ddb ends that qemu, and the guest is booted again
open(log, "w").close()
for attempt in range(4):
    p = boot()
    i = p.expect([r"login:", r"Enter pathname of shell or RETURN for /bin/sh:", pexpect.EOF, r"db\{\d+\}> "],
                 timeout=boot_to)
    if i == 0:
        break
    if i == 1:   # a dirty root fs drops to a single-user shell: repair it and reboot
        p.sendline("")
        p.sendline("fsck -y / ; reboot")
        p.expect([pexpect.EOF, r"db\{\d+\}> "], timeout=boot_to)
    p.terminate(force=True)
else:
    sys.exit("guest never reached a login prompt")
p.sendline("root")
i = p.expect([r"[Pp]assword:", r"[#%>$] ?$"], timeout=300)
if i == 0:
    p.sendline("")
    p.expect(r"[#%>$] ?$", timeout=300)
p.sendline("exec /bin/sh")
p.sendline(f"PS1='{PS}'; export PS1; stty -echo 2>/dev/null; TERM=dumb; export TERM")
p.expect_exact(PS, timeout=120)

rc = 0
with open(cmds) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        soft = line.startswith("-")
        cmd = line[1:] if soft else line
        rc = sh(cmd, cmd_to)
        print(f"GUEST {rc} {cmd[:160]}", flush=True)
        if rc and not soft:
            break
try:
    p.sendline("sync; shutdown -p now 2>/dev/null || halt -p")
    p.expect([pexpect.EOF, r"halted", r"press any key to reboot"], timeout=300)
except Exception:
    pass
p.terminate(force=True)   # some ports halt instead of powering off
sys.exit(rc)
