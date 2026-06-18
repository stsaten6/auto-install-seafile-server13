# Seafile CE 13.0 One-Click Deployment Script for Kylin V10

**Easy installation of Seafile Community Edition 13.0 on Kylin Linux Advanced Server V10 (Halberd) – also works as a reference for other Linux distributions.**

---

## 📖 Background

The official Seafile manual provides detailed steps, but it lacks a **maintained one-click installation script**. For beginners or those deploying on niche platforms like Kylin V10, the process can be complex and time‑consuming.

This repository shares a **ready‑to‑use Bash script** that automates the entire deployment:

- Pulls all required Docker images from a reliable Chinese mirror (Huawei Cloud).
- Tags images to standard names for compatibility.
- Generates environment variables and `docker-compose.yml`.
- Starts all services and creates an admin account.
- Outputs all generated passwords for immediate login.

It was developed and tested on **Kylin Linux Advanced Server V10 (Halberd)**, but the logic can be adapted to other RPM‑ or Debian‑based systems.

---

## ⚠️ Disclaimer

- This script is provided **as‑is**, for educational and reference purposes.
- It is **not** an official Seafile product. The author assumes **no liability** for any direct or indirect damages, data loss, or legal consequences resulting from its use.
- Always review the script and adjust it to your environment before running.
- Use of third‑party Docker images (from Huawei Cloud) is at your own risk. You may replace them with other registries if needed.

---

## ✅ What the Script Does

1. Checks that Docker and `docker compose` are available.
2. Pulls the following images from Huawei Cloud SWR:
   - `mariadb:10.11`
   - `memcached:1.6`
   - `redis:7`
   - `caddy:2`
   - `seafileltd/seafile-mc:13.0-latest` (Seafile server – the name `seafile-mc` in the mirror is equivalent to the official `seafileltd/seafile:13.0-latest`)
   - `seafileltd/seadoc:latest`
3. Tags them to their standard Docker Hub names so that the official `docker-compose.yml` works unchanged.
4. Creates a project directory (`/opt/seafile` by default) with `.env` and `docker-compose.yml`.
5. Generates random secure passwords for MySQL, Seafile admin, and JWT (you can override them).
6. Starts all containers and waits until the Seafile web interface is ready.
7. Prints a summary with the access URL and all credentials.

---

## 🚀 Quick Start (on Kylin V10)

> **Prerequisites:** Docker and the `docker compose` plugin must already be installed.  
> Run all commands as **root** or with `sudo`.

```bash
# 1. Download the script
wget https://raw.githubusercontent.com/your-username/your-repo/main/install_seafile.sh

# 2. Make it executable
chmod +x install_seafile.sh

# 3. Run it
sudo ./install_seafile.sh
```

After a few minutes you will see:

```
============================================================
  Seafile CE 13.0 deployed!
  URL: http://<server-ip>
  Admin email: admin@example.com
  Admin password: <randomly-generated>
  ...
============================================================
```

Open the URL in a browser and log in with the given credentials.

---

## 🛠️ Customisation

At the top of the script, you can edit the following variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTALL_DIR` | `/opt/seafile` | Where Seafile data and configs are stored |
| `DOMAIN_OR_IP` | *(auto‑detected)* | Server domain or IP address |
| `ADMIN_EMAIL` | `admin@example.com` | Seafile admin email |
| `ADMIN_PASSWORD` | *(auto‑generated)* | Admin password (leave empty to generate) |
| `MYSQL_ROOT_PASSWORD` | *(auto‑generated)* | MySQL root password |
| `SEAFILE_MYSQL_PASSWORD` | *(auto‑generated)* | Seafile database user password |
| `JWT_PRIVATE_KEY` | *(auto‑generated)* | JWT signing key |

To set a fixed password, simply change the value before running the script.

---

## 🌐 Network / Mirror Notes

The script uses the **Huawei Cloud SWR mirror** (`swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io`) to pull images.  
If you are in a different network environment where that mirror is unreachable, you can:

- Replace the `HW` registry prefix inside the script with another available mirror.
- Use offline image import: pull the images on a connected machine, save them with `docker save`, transfer to the server, and `docker load` them before running the script.

---

## 📂 Repository Structure

```
├── install_seafile.sh      # The one‑click deployment script
└── README.md               # This file
```

---

## 📜 License

This project is shared without any formal license. You are free to use, modify, and distribute the script for your own needs. **No warranties, no liabilities.**

---

## 🤝 Contributing

If you have improvements, adaptations for other systems, or bug fixes, feel free to open an issue or pull request – it will help other beginners who struggle with Seafile deployment.
