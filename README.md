# Gophish Automation Scripts

Automated Gophish phishing framework setup scripts with TLS certificate generation via Let's Encrypt Certbot.

## Overview

This repository provides two bash scripts to automate Gophish deployment:

1. **gophish_setup_helper.sh** - Basic setup with manual Namecheap DNS configuration
2. **gophish_namecheap_auto_setup.sh** - Full automation with Namecheap API integration (see installation below)

## Script 1: Basic Setup (Manual DNS)

### Features
- Downloads and extracts Gophish release from GitHub
- Updates `config.json` to bind admin server on `0.0.0.0:3333`
- Runs Certbot DNS-01 challenge with manual TXT record creation
- Provides guidance for Namecheap DNS A and TXT records

### Prerequisites
```bash
sudo apt update
sudo apt install -y curl unzip python3 certbot
```

### Usage
```bash
chmod +x gophish_setup_helper.sh
./gophish_setup_helper.sh
```

The script will prompt you for:
- Domain name (e.g., `your-domain.com`)
- Installation directory (e.g., `/opt` or `/home/ubuntu/tools`)
- Gophish version (e.g., `v0.12.1`)

During Certbot execution, create the TXT record in Namecheap:
- **Host**: `_acme-challenge`
- **Value**: (shown by Certbot)

Then create the A record:
- **Host**: `@`
- **Value**: Your server's public IP

---

## Script 2: Full Automation (Namecheap API)

### Features
- Everything from Script 1, plus:
- Automatic DNS zone management via Namecheap API
- Automated TXT record creation/deletion for Certbot DNS-01 validation
- Automatic A record setup
- No manual DNS steps required

### Prerequisites

#### 1. Install dependencies
```bash
sudo apt update
sudo apt install -y curl unzip python3 certbot xmlstarlet jq
```

#### 2. Enable Namecheap API access
1. Log in to Namecheap
2. Go to **Profile > Tools > API Access**
3. Enable API access
4. Whitelist your server's public IP
5. Note your **API Username** and **API Key**

#### 3. Download the script

Since the Namecheap automation script is large (500+ lines), download it directly:

```bash
curl -o gophish_namecheap_auto_setup.sh https://raw.githubusercontent.com/kislaysingh/gophish-automation/main/gophish_namecheap_auto_setup.sh
chmod +x gophish_namecheap_auto_setup.sh
```

**OR** create it manually by visiting:
https://github.com/kislaysingh/gophish-automation/new/main?filename=gophish_namecheap_auto_setup.sh

### Usage
```bash
./gophish_namecheap_auto_setup.sh
```

The script will prompt for:
- Domain name
- Installation path
- Gophish version
- Namecheap API username
- Namecheap account username
- Namecheap API key
- Whitelisted client IP
- Server public IP
- DNS TTL (default: 300)
- DNS propagation wait time (default: 90 seconds)

---

## Post-Installation

After either script completes:

1. **Review Gophish config**:
   ```bash
   nano /path/to/gophish/config.json
   ```

2. **Update phish_server to use your domain and TLS certs**:
   ```json
   "phish_server": {
     "listen_url": "0.0.0.0:443",
     "use_tls": true,
     "cert_path": "/etc/letsencrypt/live/your-domain.com/fullchain.pem",
     "key_path": "/etc/letsencrypt/live/your-domain.com/privkey.pem"
   }
   ```

3. **Start Gophish**:
   ```bash
   cd /path/to/gophish
   sudo ./gophish
   ```

4. **Access admin panel**:
   - URL: `https://your-server-ip:3333`
   - Default credentials shown in terminal on first run

---

## Security Notes

- **API Keys**: Never commit Namecheap API credentials to version control
- **Firewall**: Restrict admin port `3333` to trusted IPs only
- **Permissions**: Run Gophish as non-root where possible (may need `setcap` for port 443)
- **Certificate Renewal**: Set up a cron job for Certbot auto-renewal:
  ```bash
  sudo crontab -e
  # Add:
  0 3 * * * certbot renew --quiet && systemctl reload gophish
  ```

---

## Troubleshooting

### DNS Propagation
If Certbot fails DNS validation:
```bash
# Check TXT record propagation
dig +short TXT _acme-challenge.your-domain.com
# Or use
nslookup -type=TXT _acme-challenge.your-domain.com
```

### Namecheap API Issues
- Verify your client IP is whitelisted in Namecheap API settings
- Ensure domain uses Namecheap BasicDNS (not third-party)
- Check API key is for production (not sandbox)

### Port 443 Permission
```bash
# Grant Gophish binary cap_net_bind_service
sudo setcap cap_net_bind_service=+ep /path/to/gophish/gophish
```

---

## License

MIT License - Use at your own risk. Always ensure compliance with applicable laws and organizational policies when conducting phishing simulations.

## Contributing

Pull requests welcome for:
- Additional DNS provider integrations
- Systemd service templates
- Nginx reverse proxy configs
- Docker/Docker Compose setups

---

## References

- [Gophish Official Docs](https://docs.getgophish.com/)
- [Certbot Documentation](https://eff-certbot.readthedocs.io/)
- [Namecheap API Docs](https://www.namecheap.com/support/api/intro/)
