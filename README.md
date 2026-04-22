# 🪣 Filone S3 RAM-Backed Mount

A Bash script that mounts an S3-compatible bucket (via [Fil.one](https://fil.one)) directly into your filesystem using [`mount-s3`](https://github.com/awslabs/mountpoint-s3), accelerated by a **RAM-backed tmpfs cache** for high-speed read/write operations.

---

## ✨ Features

- 🧠 **RAM Disk Cache** — Allocates 80% of available RAM as a tmpfs cache for blazing-fast S3 I/O
- ☁️ **S3-Compatible** — Works with Fil.one (and any S3-compatible endpoint)
- 🔐 **sudo-safe** — Detects the real user even when run with `sudo`, using their `~/.aws/credentials`
- 🧹 **Auto Cleanup** — Gracefully unmounts and removes directories on `CTRL+C` or `SIGTERM`
- 🗂️ **Non-invasive** — All mount points are created inside the user's home directory

---

## 📋 Requirements

| Dependency | Notes |
|---|---|
| [`mount-s3`](https://github.com/awslabs/mountpoint-s3) | AWS Mountpoint for S3 |
| `fuse` / `fusermount` | Required for FUSE-based mounts |
| `tmpfs` support | Standard on all modern Linux kernels |
| AWS credentials | Configured via `~/.aws/credentials` with a `[default]` profile |

> **Note:** For `--allow-other` to work, ensure `/etc/fuse.conf` contains:
> ```
> user_allow_other
> ```

---

## ⚙️ Configuration

Edit the configuration block at the top of the script:

```bash
S3_BUCKET="benjiworld"                       # Your S3 bucket name
ENDPOINT="https://eu-west-1.s3.fil.one"     # S3-compatible endpoint
REGION="eu-west-1"                           # Endpoint region
```

Mount paths are automatically resolved relative to the real user's home directory:

| Path | Default | Purpose |
|---|---|---|
| `$ACTUAL_HOME/FiloneRAM` | `~/FiloneRAM` | S3 mount point (visible) |
| `$ACTUAL_HOME/.Filone_RAM_Cache` | `~/.Filone_RAM_Cache` | RAM disk cache (hidden) |

---

## 🚀 Usage

```bash
sudo bash filone_mount.sh
```

The script must be run with `sudo` to allocate the tmpfs RAM disk. It will automatically detect your real user account via `$SUDO_USER`.

**Expected output:**
