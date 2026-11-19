![alt text](06cd562d2fe446d5e46a35356f46aa36e47be79acfd1a1d6297329b8f1b6d291_1.jpg)

# Cock-inspector
Cock inspector is a mini script based project that generate markdown audits of debian based server. Very useful when you forgot what you did on a machine like dumb bitch like me

# How to use it: 
copy the script to the server, by scp once you can log in or by pasting it in through console access. Then run:
```
sudo bash server-audit.sh                    # writes ./server-config-<hostname>-<date>.md
sudo bash server-audit.sh -o /root/neuro.md  # pick the output path
sudo bash server-audit.sh --redact           # mask passwords/tokens/keys
```
## What's in the report:
- Summary at the top: OS, IPs, CPU/RAM, disk use, which web servers, databases and Docker containers it found, and a table of every listening port with the process behind it.
- Sections: system, storage, network, firewall, users and SSH access (sshd effective settings, authorized_keys fingerprints, each user's ~/.ssh), services (plus the contents of custom systemd units), web servers and TLS cert expiry dates.
- Docker: each container's image, ports, mounts, restart policy and environment variables, plus its compose files and .env.
- Apps: databases (version, database list, config), deployed apps (git remote and commit, .env files, runtimes, Supervisor/PM2), cron jobs and systemd timers, backups, logging, manually installed packages, and kernel/sysctl tuning.
- "Could not collect" at the end: anything it couldn't read, for example because it wasn't run as root.

## Things to know:
- It's read-only. It only reads files and runs status/list commands. It never restarts, installs or edits anything. Git checks use --no-optional-locks so they don't even touch repo index files.
- Secrets are included by default, as you chose earlier, and the doc starts with a warning about that. The file is created with 600 permissions. Use --redact if the doc will be shared.
- Run it as root. Without root, firewall rules, other users' crontabs, nginx -T, database details and process names on ports will be missing.
