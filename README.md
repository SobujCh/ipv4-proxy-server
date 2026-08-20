# IPv4 Proxy Server

A Bash script for Ubuntu/Debian that automatically detects public IPv4 addresses on a server and starts an **HTTP proxy** on each one. Every proxy listener binds outbound traffic to its assigned IPv4, so each port exits through a different source address.

Built on [3proxy](https://github.com/z3APA3A/3proxy).

## Features

- Auto-detects public IPv4 addresses from network interfaces
- One HTTP proxy port per public IPv4 (outbound IP binding)
- Optional username/password authentication
- Installs 3proxy via apt or builds from source if needed
- Simple start / stop / restart / status controls

## Requirements

- Ubuntu or Debian server
- Root access (`sudo`)
- Public IPv4 address(es) configured on the host
- `iproute2` (usually preinstalled)

## Quick Start

```bash
chmod +x ipv4-proxy-server.sh
sudo ./ipv4-proxy-server.sh -u pxuser -p your-password
```

On success, the script prints a list of proxy URLs, one per detected IPv4.

### Example output

```
HTTP proxies ready (one outbound IPv4 per port):
------------------------------------------------
  203.0.113.10     http://pxuser:your-password@203.0.113.10:30000
  203.0.113.11     http://pxuser:your-password@203.0.113.11:30001

Config : /etc/ipv4-proxy-server/3proxy.cfg
Log    : /var/log/ipv4-proxy-server.log
PID    : 12345
```

## Usage

```bash
./ipv4-proxy-server.sh [OPTIONS]
```

| Option | Description |
|--------|-------------|
| `-u USER` | Proxy username (requires `-p`) |
| `-p PASS` | Proxy password (requires `-u`) |
| `-b PORT` | First port to use (default: **30000**) |
| `-a ACTION` | `start`, `stop`, `restart`, or `status` (default: `start`) |
| `-h` | Show help |

### Examples

```bash
# Start with authentication
sudo ./ipv4-proxy-server.sh -u pxuser -p your-password

# Start without authentication
sudo ./ipv4-proxy-server.sh

# Use a custom starting port
sudo ./ipv4-proxy-server.sh -b 20000 -u pxuser -p secret

# Stop / restart / check status
sudo ./ipv4-proxy-server.sh -a stop
sudo ./ipv4-proxy-server.sh -a restart -u pxuser -p your-password
sudo ./ipv4-proxy-server.sh -a status
```

## How It Works

1. **Detect IPs** — Reads global-scope IPv4 addresses with `ip -4 -o addr show scope global` and filters out private/reserved ranges (RFC1918, loopback, link-local, CGNAT, etc.).
2. **Assign ports** — Maps each public IPv4 to a consecutive port starting at `30000` (or `-b` value): first IP → 30000, second → 30001, and so on.
3. **Generate config** — Writes a 3proxy config with one `proxy -pPORT -eIP` line per address.
4. **Authentication** — If both `-u` and `-p` are provided, enables `auth strong`. Otherwise runs with `auth none`.
5. **Start 3proxy** — Launches 3proxy as a background daemon.

## Authentication

| Flags | Behavior |
|-------|----------|
| `-u` and `-p` both set | Password authentication required |
| Neither set | Open proxies (no authentication) |
| Only one set | Script exits with an error |

**Always use `-u` and `-p` on internet-facing servers.** Without authentication, anyone who can reach the ports can use your proxies.

## Port Assignment

With 3 public IPv4 addresses and the default base port:

| Public IPv4 | Port |
|-------------|------|
| 203.0.113.10 | 30000 |
| 203.0.113.11 | 30001 |
| 203.0.113.12 | 30002 |

Base port must be between **1024** and **65500** (to leave room for additional IPs).

## Firewall

Allow the proxy port range through your firewall. Example with UFW for 3 IPs starting at 30000:

```bash
sudo ufw allow 30000:30002/tcp
```

Adjust the range to match your number of public IPv4 addresses.

## Files

| Path | Purpose |
|------|---------|
| `/etc/ipv4-proxy-server/3proxy.cfg` | Generated 3proxy configuration |
| `/etc/ipv4-proxy-server/proxy-map.txt` | IP-to-port mapping |
| `/var/run/ipv4-proxy-server.pid` | Process ID file |
| `/var/log/ipv4-proxy-server.log` | 3proxy log file |

## Using the Proxies

Configure your HTTP client to use the proxy URL for the outbound IP you want:

```bash
# curl example (authenticated)
curl -x http://pxuser:your-password@203.0.113.10:30000 https://api.ipify.org

# curl example (no auth)
curl -x http://203.0.113.10:30000 https://api.ipify.org
```

Each proxy exits through its bound IPv4, so `api.ipify.org` (or similar) should return the matching source address.

## Troubleshooting

**No public IPv4 addresses detected**

The server has no global-scope public IPv4 on any interface. Confirm addresses with:

```bash
ip -4 -o addr show scope global
```

**3proxy failed to start**

Check the log:

```bash
sudo tail -50 /var/log/ipv4-proxy-server.log
```

**Port already in use**

Pick a different base port with `-b`, or stop the conflicting service.

**Already running**

Stop or restart before starting again:

```bash
sudo ./ipv4-proxy-server.sh -a stop
sudo ./ipv4-proxy-server.sh -u pxuser -p your-password
```

## License

Use at your own risk. Ensure compliance with your provider's terms of service and applicable laws when operating open or authenticated proxies.
