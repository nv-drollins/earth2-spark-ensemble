# Laptop (Windows + WSL2) setup — one-time, do before you travel

Goal: your Windows laptop drives the Spark cluster from inside WSL2 Ubuntu, and
(optionally) I can reach it over SSH to configure and dry-run it from here.

Everything the demo needs runs **inside WSL**. Nothing is installed on Windows
itself except the SSH access in Part B, which is only there so I can help.

---

## Part A — WSL2 Ubuntu (required)

### A1. Install WSL2 with Ubuntu

In **PowerShell as Administrator** on the laptop:

```powershell
wsl --install -d Ubuntu
wsl --update
```

Reboot if it asks. Then open **Ubuntu** from the Start menu and create your
Linux username and password when prompted.

### A2. Confirm you are on WSL **2**

```powershell
wsl -l -v
```

The `VERSION` column must say `2`. If it says `1`:

```powershell
wsl --set-version Ubuntu 2
```

### A3. Install what the demo needs, inside Ubuntu

In the **Ubuntu** window:

```bash
sudo apt update
sudo apt install -y python3-venv python3-pip git openssh-client rsync
```

### A4. Clone the repo and build the venv

```bash
cd ~
git clone https://github.com/nv-drollins/earth2-spark-ensemble.git
cd earth2-spark-ensemble
python3 -m venv .venv
.venv/bin/pip install -r viz/requirements.txt
.venv/bin/python -c "import fastapi, uvicorn, jinja2, PIL, numpy; print('viz deps OK')"
```

That last line must print `viz deps OK`.

### A5. Create an SSH key for reaching the Sparks

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

This is the key you will `ssh-copy-id` to each Spark at the venue.

---

## Part B — Let me reach the laptop over SSH (optional but recommended)

This lets me configure WSL, run a full dry-run against the lab Sparks, and fix
whatever breaks — before you travel, instead of at the booth.

### B1. Run an SSH server inside WSL

In **Ubuntu**:

```bash
sudo apt install -y openssh-server
sudo sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo service ssh restart
sudo service ssh status | head -3
```

**Port 2222, not 22** — Windows may already use 22, and this avoids the clash
entirely.

### B2. Switch WSL to mirrored networking

Without this, WSL2 sits behind a NAT with its own private IP and inbound
connections need `netsh portproxy` rules that break on every restart. Mirrored
mode makes WSL share the laptop's real IP, so `192.168.1.142:2222` just works.

Requires **Windows 11 22H2 or newer**. In **PowerShell** (normal, not admin):

```powershell
notepad "$env:USERPROFILE\.wslconfig"
```

Put exactly this in the file and save:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
```

Then, back in PowerShell:

```powershell
wsl --shutdown
```

Reopen Ubuntu. It will take a few seconds to start.

### B3. Allow inbound connections through the Hyper-V firewall

**This is the step that is almost always missed.** Mirrored mode puts WSL
behind a *separate* Hyper-V firewall; without this rule the port looks open
from inside WSL and refuses from everywhere else.

In **PowerShell as Administrator**:

```powershell
Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow
New-NetFirewallHyperVRule -Name "WSL-SSH" -DisplayName "WSL SSH 2222" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 2222
```

That GUID is WSL's fixed VM creator ID — it is the same on every machine, not
something specific to your laptop.

Also allow it through the normal Windows firewall:

```powershell
New-NetFirewallRule -DisplayName "WSL SSH 2222" -Direction Inbound -Protocol TCP -LocalPort 2222 -Action Allow
```

### B4. Confirm it is listening and tell me

In **Ubuntu**:

```bash
ss -tln | grep 2222        # expect 0.0.0.0:2222 or *:2222
whoami                     # tell me this username
```

Then tell me the username and I will connect to `192.168.1.142:2222` and take
it from there. You will need to give me the password once; I will install a key
so it is not needed again.

---

## If mirrored networking is not available

If `.wslconfig` has no effect (Windows 10, or an older Windows 11), fall back
to port forwarding. In **PowerShell as Administrator**:

```powershell
$wslIp = (wsl hostname -I).Trim().Split()[0]
netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=$wslIp
netsh interface portproxy show all
New-NetFirewallRule -DisplayName "WSL SSH 2222" -Direction Inbound -Protocol TCP -LocalPort 2222 -Action Allow
```

**Caveat:** WSL's IP changes on most restarts, so re-run the first two lines
after any reboot or `wsl --shutdown`. This is exactly the fragility mirrored
mode removes — prefer Part B2 when you can.

---

## What this does NOT change

- **The Sparks never connect to the laptop.** The laptop only makes outbound
  SSH connections to them. Part B exists solely so I can help set it up.
- **At the venue you do not need any of Part B.** Only Part A matters there.
- **`cluster.conf` is unchanged.** Site details live in `~/.ssh/config` inside
  WSL, exactly as in the main runbook.
