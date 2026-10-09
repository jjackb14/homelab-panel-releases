# homelab-panel

homelab-panel is a web page for looking after a small Proxmox VE cluster. It does two jobs:

- **Updates.** It shows which packages are waiting to be updated on every node, container and
  virtual machine, and lets you update one or many with a click. You watch the update happen
  live, the panel takes a snapshot first where it can, and if an update is interrupted there is
  a Repair button.
- **Files.** It lets you browse the storage on every node, upload and download files, and copy
  or move folders between nodes, with a progress bar, a cancel button and Undo.

It is a single program with the web page built in, and it runs in its own small container on
your cluster. This repository holds its releases and the scripts that install and update it.

## What you need

- Proxmox VE 9, on one node or a cluster.
- Root access to one of your nodes, to run the installer.
- About 4 GB of disk space and 512 MB of memory for the panel's container.
- Optional: a [Tailscale](https://tailscale.com) account, if you want to reach the panel when you
  are away from home.

## Install

Open a shell on any of your Proxmox nodes (in the Proxmox web interface: click the node, then
**Shell**), and paste this line:

```sh
bash -c "$(curl -fsSL https://github.com/jjackb14/homelab-panel-releases/releases/latest/download/install.sh)"
```

The installer looks and works like the
[community-scripts](https://community-scripts.github.io/ProxmoxVE/) installers you may already
know. It is its own code, though, and downloads nothing from community-scripts.

### The questions it asks

First, a menu:

- **Default Install** creates the container with sensible settings: the next free container ID,
  1 CPU core, 512 MB of memory, a 4 GB disk, and a network address from your router (DHCP).
- **Advanced Install** walks you through each setting, one screen at a time, the same way
  community-scripts does: container type, root password, container ID, name, disk size, CPU,
  memory, network, DNS, VLAN, tags, SSH access and verbose mode. **Cancel** takes you back one
  screen, and the last screen shows everything you chose before anything is created.

Then, either way, three questions about the panel itself:

1. **Install Tailscale?** If you say yes, the container joins your Tailscale network, and you can
   open the panel from your phone or laptop wherever you are. The installer prints a link: open
   it, approve the device, and you're done.
2. **Add the panel's SSH key to your nodes?** The panel runs updates and moves files by logging in
   to your nodes over SSH, as root. Saying yes adds its key to Proxmox's shared list of allowed
   keys, so it can. If you say no, the panel can still show your cluster, but updates and file
   operations won't work until you add the key yourself (the installer prints it).
3. **A password for the panel's sign-in page.** At least 10 characters. Every device signs in
   with it; a sign-in lasts 30 days from the last time you used the panel.

### What it changes on your cluster

- A new **unprivileged Debian 13 container**, running the panel as a background service.
- A Proxmox user **`panel@pve`** with an **API token**, and a role **`PanelRole`** that allows
  only what the panel uses: reading the cluster's state, listing package updates, taking
  snapshots, and restarting guests.
- If you said yes: **one line** in `/etc/pve/priv/authorized_keys`, the panel's SSH key.
- If you chose Tailscale: **one new device** on your tailnet.

Nothing that is already running is restarted. Every file the installer downloads is checked
against the release's published checksums (`.sha256` files) before anything is created. If any
step fails, the installer tells you which one, shows why, lists what it had already created, and
gives you the command to remove each of those things.

### When it's done

The installer prints the panel's address:

- on your home network: `http://<the container's address>:8420`
- on your tailnet, if you chose Tailscale: `http://homelab-panel:8420`

Open it, sign in with the password you chose, and go to **Settings**: every node should show
**API ok** and **SSH ok**.

## Security, in short

- **The panel is powerful.** With its SSH key on your nodes it can log in to them as root,
  because installing updates and moving files needs that. Treat the panel's password like the
  root password of your cluster.
- **Keep it off the internet.** It is meant to be reached from your home network or your tailnet,
  not exposed to the public internet. It uses plain HTTP; Tailscale encrypts the connection for
  you when you use it.
- **Every page needs the password.** The panel refuses to run without one when other machines
  can reach it. Too many wrong passwords lock that device out for a while.
- **It runs as its own user**, fenced off from the rest of its container: the only place it can
  write is its own data folder.
- **No secrets on command lines.** The installer passes the API token and your passwords through
  files and pipes, never as part of a command, because commands can be seen by anyone on the
  node while they run.

## Update

From the shell of the node that hosts the panel's container:

```sh
pct exec <ctid> -- homelab-panel-update            # the newest release
pct exec <ctid> -- homelab-panel-update v0.1.0     # a particular release, including an older one
```

Replace `<ctid>` with the panel container's ID. The updater checks every download, keeps the
current version, and if the new version doesn't start within 20 seconds it puts the old one back
automatically. Your settings, password and history are never touched.

## Change the password

From the node that hosts the panel's container:

```sh
pct exec <ctid> -- su -s /bin/sh homelab-panel -c 'PANEL_DATA_DIR=/var/lib/homelab-panel /opt/homelab-panel/homelab-panel set-password'
pct exec <ctid> -- systemctl restart homelab-panel
```

Every device is signed out and signs in again with the new password.

## Install without the questions

Every answer can be given ahead of time with an environment variable, using the same names as
community-scripts. With `NONINTERACTIVE=1` no screens are shown at all, and the panel's password
is read from a file you name:

```sh
printf '%s\n' 'your panel password' > /root/panel-password && chmod 600 /root/panel-password
NONINTERACTIVE=1 var_ctid=150 var_tailscale=no var_add_key=yes \
  var_password_file=/root/panel-password \
  bash -c "$(curl -fsSL https://github.com/jjackb14/homelab-panel-releases/releases/latest/download/install.sh)"
rm /root/panel-password
```

The full list of settings, with what each one means, is at the top of
[`deploy/install.sh`](deploy/install.sh).

## If something goes wrong

- **"has no working DNS"**: the new container couldn't look up web addresses. Check the DNS
  server you gave it (Advanced Install → DNS SERVER), or that the node itself has internet access.
- **"does not match its checksum"**: a download was damaged or changed on the way. Nothing was
  installed. Try again; if it keeps happening, don't use that release.
- **"panel@pve already has an API token"**: an earlier install is still registered with
  Proxmox. If that install is gone, remove the old token with
  `pveum user token remove panel@pve panel` and run the installer again.
- **Settings shows SSH failing**: the panel's key isn't on your nodes yet. Its public key is in
  the container at `/etc/homelab-panel/ssh/id_ed25519.pub`; add that line to
  `/etc/pve/priv/authorized_keys` on any node.
- **The panel's own log**: `pct exec <ctid> -- journalctl -u homelab-panel -n 50`.

## Remove

Run these on any node. Each line removes one thing the installer created:

| What | How |
|---|---|
| the container | `pct stop <ctid> && pct destroy <ctid>` |
| `panel@pve`, its token, and `PanelRole` | `pveum user delete panel@pve && pveum role delete PanelRole` |
| the panel's SSH key | delete the line ending `homelab-panel-ct<ctid>` in `/etc/pve/priv/authorized_keys` |
| the Debian template (if nothing else uses it) | `pveam remove <storage>:vztmpl/<template>` |
| the tailnet device | remove it from the Machines page of the Tailscale admin console |

## What's in this repository

| File | What it is |
|---|---|
| `deploy/install.sh` | the installer described above |
| `deploy/update.sh` | the updater, installed in the container as `homelab-panel-update` |
| `deploy/homelab-panel.service` | tells the container's system how to run the panel |
| `deploy/panel.env.example` | the panel's settings file, with an explanation of each setting |

Every file is commented in plain English, so you can read what it does before you run it. The
panel itself is attached to each [release](https://github.com/jjackb14/homelab-panel-releases/releases),
along with a checksum for every file.

## License

MIT; see [`LICENSE`](LICENSE). The panel includes open-source software written by others. Their
licenses are listed in `THIRD-PARTY-NOTICES`, which comes with every release and is installed at
`/opt/homelab-panel/THIRD-PARTY-NOTICES`.
