># OpenDots on Proxmox - Community Script

**OpenDots** is an open-source template for persistent AI agents with local inference. This script deploys it on Proxmox with integrated Ollama backend in minutes.

![GitHub](https://img.shields.io/badge/license-MIT-green)
![Proxmox](https://img.shields.io/badge/Proxmox-8.0+-orange)
![Status](https://img.shields.io/badge/status-production%20ready-brightgreen)

## Features

✓ **Local AI Models** - Run Ollama models completely offline  
✓ **Zero Dependencies** - Self-contained, no external API calls  
✓ **Ultra-Lightweight** - ~2GB footprint, optimized for Proxmox  
✓ **LXC-Optimized** - Recommended as LXC container (400MB base)  
✓ **OpenAI Compatible** - Use with any OpenAI-compatible endpoint  
✓ **One-Click Deploy** - Ready via Proxmox Community Scripts  
✓ **Auto-Start** - Systemd service with health checks  
✓ **Fully Offline** - No external connectivity required after setup  

## Quick Start

### Option 1: Via Proxmox Web UI (Recommended)

1. In Proxmox VE Web Console → Datacenter → CT Templates
2. Search for **OpenDots** in Community Scripts
3. Create new LXC container
4. Select **OpenDots** template
5. Complete wizard (2-4 vCPU, 4-6GB RAM, 40GB storage recommended)
6. Wait ~10 minutes for automatic installation
7. Access: `http://<container-ip>:4310`

### Option 2: Manual Installation

```bash
# On Debian/Ubuntu host or Proxmox container:
bash <(curl -fsSL https://raw.githubusercontent.com/SirCaracol/proxmox-opendots-installer/main/opendots-community-script.sh)
```

### Option 3: LXC from Command Line

```bash
# SSH into Proxmox host
pct create 100 local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
  --hostname opendots \
  --cores 4 --memory 4096 --swap 2048 \
  --rootfs local:80 \
  --net0 name=eth0,bridge=vmbr0,type=veth

# Start and run installer
pct start 100
pct exec 100 -- bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/SirCaracol/proxmox-opendots-installer/main/opendots-community-script.sh)'
```

## System Requirements

### Minimum (Works, but slower)
- **vCPU:** 2 cores
- **RAM:** 4 GB
- **Storage:** 40 GB SSD
- **Model:** phi:3.5, smollm2:135m

### Recommended (Smooth performance)
- **vCPU:** 4 cores
- **RAM:** 6-8 GB
- **Storage:** 60 GB SSD
- **Model:** neural-chat:7b-v3.3-q4_K_M, qwen3:4b

### Ideal (Best experience)
- **vCPU:** 6-8 cores
- **RAM:** 12-16 GB
- **Storage:** 100+ GB SSD
- **Model:** neural-chat:7b, qwen3:7b, mistral

## LXC vs VM

### LXC Container (Recommended ✓)
| Aspect | LXC |
|--------|-----|
| Memory Overhead | ~300MB |
| Startup Time | 2-3 seconds |
| Storage Footprint | ~400MB base |
| Boot Speed | ~5-10s |
| Network | Native bridge |
| Use Case | **Optimal for Proxmox** |

### VM
| Aspect | VM |
|--------|---|
| Memory Overhead | ~800MB |
| Startup Time | 20-30 seconds |
| Storage Footprint | ~2GB base |
| Boot Speed | ~30-60s |
| Network | Tap/vNIC |
| Use Case | If you need Windows or special drivers |

**Recommendation:** Use **LXC** for this deployment. It's lighter, faster, and perfectly suitable for OpenDots.

## Available Models

Install via web UI or manually:

```bash
# Speed-optimized (fastest)
ollama pull phi:3.5                      # 3.8B, ultra-fast
ollama pull smollm2:135m                 # 135M, instant

# Balanced (recommended)
ollama pull neural-chat:7b-v3.3-q4_K_M   # 7B, good quality/speed
ollama pull qwen3:4b-chat-q4_K_M         # 4B, efficient

# Quality-optimized (slower)
ollama pull mistral:7b                   # 7B, better quality
ollama pull qwen3:7b-chat-q4_K_M         # 7B, highest quality
```

### Switching Models

1. SSH into container:
   ```bash
   pct exec 100 -- bash
   ```

2. Edit environment:
   ```bash
   nano /opt/opendots/.env
   # Change: OPENAI_MODEL=neural-chat:7b-v3.3-q4_K_M
   ```

3. Restart:
   ```bash
   systemctl restart opendots
   ```

## Access

| Service | URL | Default |
|---------|-----|---------|
| **OpenDots Web UI** | `http://<ip>:4310` | Port 4310 |
| **Ollama API** | `http://<ip>:11434/v1` | Port 11434 |
| **Status Check** | `curl http://<ip>:4310` | Health endpoint |

## Administration

### View Logs
```bash
pct exec 100 -- journalctl -fu opendots -n 100
```

### Check Status
```bash
pct exec 100 -- systemctl status opendots
pct exec 100 -- ollama ps
pct exec 100 -- free -h
```

### Restart Services
```bash
# Restart OpenDots
pct exec 100 -- systemctl restart opendots

# Restart Ollama
pct exec 100 -- systemctl restart ollama

# Full reboot
pct reboot 100
```

### Troubleshooting

**Out of Memory errors?**
```bash
# Switch to smaller model
ollama pull phi:3.5
# Update .env and restart
```

**Slow responses?**
```bash
# Check available resources
free -h
ps aux --sort=-%mem | head -10

# Reduce model complexity or increase container RAM
```

**Can't access web UI?**
```bash
# Check if service is running
systemctl status opendots

# Check port binding
netstat -tulpn | grep 4310

# View full logs
journalctl -fu opendots --all
```

## Performance Tuning

### For 4GB RAM Systems
```bash
# .env optimizations
NODE_OPTIONS=--max-old-space-size=1024
OPENAI_MODEL=phi:3.5
```

### For 8GB+ RAM Systems
```bash
NODE_OPTIONS=--max-old-space-size=2048
OPENAI_MODEL=neural-chat:7b-v3.3-q4_K_M
```

### Monitor Resource Usage
```bash
watch -n 2 'free -h && echo "---" && ps aux --sort=-%mem | head -5'
```

## Security

- ✓ Ollama listens only on localhost (127.0.0.1)
- ✓ OpenDots requires owner token
- ✓ Services run as unprivileged user
- ✓ SELinux/AppArmor compatible
- ✓ No external API calls when using local models

**Expose to network (optional):**
```bash
# Edit .env: APP_ORIGIN=http://your-lan-ip:4310
# Then: systemctl restart opendots
# Access: http://your-lan-ip:4310
```

## Uninstall

To remove the container:

```bash
pct stop 100
pct destroy 100
```

To remove from within container:
```bash
systemctl stop opendots ollama
rm -rf /opt/opendots /var/lib/opendots
userdel opendots
```

## Community Scripts Format

This script is designed to be used with Proxmox VE Community Scripts:

**Repository:** https://github.com/SirCaracol/proxmox-opendots-installer

**Script Location:**
- Production: `opendots-community-script.sh`
- Advanced: `install-opendots-4core-8gb.sh`

**Metadata:**
```
Name: OpenDots
Version: 1.0.0
Type: LXC/VM
OS: Debian 12, Ubuntu 24.04
Architecture: amd64, arm64
Default RAM: 4096MB
Default Storage: 40GB
```

## Useful Links

- **OpenDots GitHub:** https://github.com/CopilotKit/OpenDots
- **Ollama:** https://ollama.ai
- **CopilotKit Docs:** https://docs.copilotkit.ai
- **Community Scripts:** https://community-scripts.github.io/

## Support & Issues

- **GitHub Issues:** https://github.com/SirCaracol/proxmox-opendots-installer/issues
- **OpenDots Issues:** https://github.com/CopilotKit/OpenDots/issues
- **Ollama Issues:** https://github.com/ollama/ollama/issues

## License

This installer script is provided under the **MIT License**.

OpenDots is licensed under **MIT** by [CopilotKit](https://github.com/CopilotKit).

Ollama is licensed under **MIT** by [Ollama](https://ollama.ai).

---

**Made with ❤️ for the Proxmox Community**

Contributions welcome: https://github.com/SirCaracol/proxmox-opendots-installer
