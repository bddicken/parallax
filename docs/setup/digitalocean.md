# DigitalOcean setup

Parallax can run [`parallax-server`](../../server/README.md) for you on a DigitalOcean droplet. It takes about 10 minutes, most of it waiting. The droplet costs about $6 a month (1 vCPU, 1 GB, which is plenty: the server relays video without re-encoding it).

## 1. Create a token

1. Open [DigitalOcean › API › Tokens](https://cloud.digitalocean.com/account/api/tokens/new) and click **Generate New Token**.
2. Name it (e.g. `Parallax`), pick an expiration, and choose **Custom Scopes**.
3. Select these scopes. Parallax shows the same list in **Settings › Server › Connect DigitalOcean…**.

   | Resource | Scopes | Used to |
   |---|---|---|
   | `account` | read | Check the token |
   | `regions` | read | List regions for the droplet |
   | `droplet` | create, read, delete | Create, find, and destroy the server |
   | `firewall` | create, read, delete | Open only the server's ports |
   | `reserved_ip` | create, read, update, delete | Optional fixed address (`update` assigns it) |
   | `tag` | create, read | Tag droplets `parallax`, which the firewall follows |

   DigitalOcean may add a few scopes these depend on; keep them.
4. Click **Generate Token** and copy it (it's shown once).

## 2. Connect Parallax

In Parallax, open **Settings › Server**, click **Connect DigitalOcean…**, and paste the token. Parallax checks it and keeps it in your Keychain.

## 3. Deploy

1. Click **Deploy New Server…**.
2. Pick the region nearest you. Optionally turn on **Reserve a static IP**, which keeps the server's address if you ever replace the droplet (DigitalOcean charges for a reserved IP while it isn't assigned to a droplet).
3. Fill in the platforms you use, from their guides: [Twitch](twitch.md), [YouTube](youtube.md), [X](x.md). Leave the rest empty. You can skip the "configure the server" steps in those guides: these fields do that.
4. Click **Deploy**.

Parallax then:

1. Creates a `parallax` firewall that lets in 80 and 443 (HTTPS) and 8890/udp (SRT video), and nothing else.
2. Creates an Ubuntu 24.04 droplet tagged `parallax`. On first boot it runs [`server/deploy/cloud-init.sh`](../../server/deploy/cloud-init.sh), which installs ffmpeg, Caddy, MediaMTX, and the parallax-server release matching your version of Parallax.
3. Waits for the server to answer at `https://<ip>.sslip.io` ([sslip.io](https://sslip.io) turns the IP into a name, so Caddy can get a certificate without a domain of your own). This takes a few minutes.
4. Fills in the server URL and token, and connects.

Then connect your accounts in the **Accounts** section as usual.

The API token and SRT passphrase are generated on your Mac for each server, and the video upload is encrypted with that passphrase.

## Managing servers

**Settings › Server › Deploy** lists every droplet tagged `parallax`, with its region, address, and version.

- **Use**: switch Parallax to that server. Only for servers deployed from this Mac, since it needs their token.
- **Update to x.y.z**: shown when a newer parallax-server release matches your version of Parallax. The server downloads it, checks that it runs, and restarts into it. Stop broadcasting first.
- **Destroy…**: deletes the droplet and its reserved IP, and the firewall once no Parallax servers are left. Platform sign-ins saved on the server go with it.

Platform settings (client IDs, X's stream key) live on the droplet. To change them, deploy a new server and destroy the old one.

## Troubleshooting

| Message | Fix |
|---|---|
| "didn't accept the token" | Paste the whole token (it starts with `dop_v1_`), and check it hasn't expired. |
| "missing a permission" | The token lacks a scope from step 1. Generate a new one with all of them. |
| "didn't answer in time" | The droplet is still there. Log in to it (below) and read `/var/log/cloud-init-output.log`. Destroy it and deploy again once the problem is fixed. |
| "You have reached your droplet limit" | Destroy an unused droplet, or ask DigitalOcean to raise the limit. |
| Update fails with a 404 | That parallax-server version hasn't been released yet (see [releasing](../../server/README.md#releases)). |

To log in to the droplet, the `parallax` firewall blocks SSH, so either use the droplet's **Recovery Console** on DigitalOcean (as `root`, with the password DigitalOcean emails when a droplet has no SSH key), or temporarily add an SSH (22/tcp) rule to the firewall. The server's logs are in `journalctl -u parallax`, the install's in `/var/log/cloud-init-output.log`, and the server's settings in `/etc/parallax/parallax.env`.
