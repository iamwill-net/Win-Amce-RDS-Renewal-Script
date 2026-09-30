# Update-RDSCertificate

A [win-acme](https://www.win-acme.com/) installation script that applies a renewed Let's Encrypt certificate to a Remote Desktop Services deployment automatically. It replaces the manual steps after each renewal:

- **Server Manager → Remote Desktop Services → Tasks → Edit Deployment Properties → Certificates**: sets the certificate on RD Connection Broker (Enable SSO), RD Connection Broker (Publishing), RD Web Access and RD Gateway
- **RD Web Client**: imports the broker certificate (`Import-RDWebClientBrokerCert`) and republishes the client (`Publish-RDWebClientPackage -Type Production -Latest`)

It needs no parameters. The Connection Broker, the installed roles, the Web Access servers and the certificate are all detected on the server it runs on, so the same script works at every site.

## How it works

1. **Finds the Connection Broker**: the local server if it is the broker, otherwise the member of the local **RDS Management Servers** group that answers as a broker.
2. **Finds the certificate**: the newest valid Let's Encrypt certificate with a private key in the **Web Hosting** or **Personal** store of the local machine.
3. **Sets the deployment certificates** through the broker, only for the roles that are installed (Gateway and Web Access are skipped if not deployed).
4. **Updates the RD Web Client** on each RD Web Access server, if the web client is installed. Otherwise it logs "skipped".
5. **Logs** every step to `%ProgramData%\win-acme\Update-RDSCertificate.log`. On failure it exits with code 1, so win-acme records the renewal as failed.

## Per-site setup (one time)

Do this on the server that runs win-acme. In the standard setup that's the **RD Gateway / RD Web Access server**.

1. **Copy the script** into the `Scripts` folder inside the win-acme folder (next to `wacs.exe`, e.g. `C:\win-acme\Scripts\Update-RDSCertificate.ps1`), then unblock it (files downloaded from GitHub are blocked by default):
   ```powershell
   Unblock-File <win-acme folder>\Scripts\Update-RDSCertificate.ps1
   ```
2. **Make the private key exportable.** In the win-acme folder, edit `settings.json` and set:
   ```json
   "Store": {
     "CertificateStore": {
       "PrivateKeyExportable": true
     }
   }
   ```
   This only applies to certificates issued *after* the change. If a certificate already exists, force a renewal once it's set.
3. **Give the gateway rights on the broker.** Automatic renewals run as SYSTEM, which connects to the broker as the gateway's computer account. On the **Connection Broker**, add `<GATEWAY-NAME>$` (for example `DOMAIN\RDG01$`) to the local **Administrators** group, then **reboot the gateway** so it picks up the new group membership.

   Skip this step if win-acme runs on the broker itself.

## Creating the certificate in win-acme

Run `wacs.exe` and follow the usual flow. Only the installation step is different.

| Prompt | Answer |
|---|---|
| Main menu | **M**: Create certificate (full options) |
| Source / hostname | As usual (pick the RDS hostname from IIS) |
| Validation | Cloudflare DNS (as usual) |
| Key type | Default |
| How to store the certificate | Default (Windows Certificate Store), then **No** to additional stores |
| Which installation step should run first | **Start external script or program** |
| Path to script | `Scripts\Update-RDSCertificate.ps1` |
| Parameters | *Leave blank*, just press **Enter** |
| Add another installation step | **No** |
| Scheduled task | Default |

The wording of the prompts varies slightly between win-acme versions.

### Existing renewals

- **win-acme 2.2 or later:** **Manage renewals**, select the renewal, choose the edit option and change the installation steps as above.
- **Older versions:** run through **M** again with the same hostname. It replaces the existing renewal.

Then **force a renewal** once to test it.

## Checking it worked

1. Read the log:
   ```powershell
   Get-Content "$env:ProgramData\win-acme\Update-RDSCertificate.log" -Tail 20
   ```
   A successful run shows:
   - `Auto-detected Connection Broker: ...`
   - `Applying certificate ...`
   - one `Set-RDCertificate -Role ...` line per role
   - a line for each Web Access server (`Web client broker cert imported and package published`, or the reason it was skipped)
   - `Completed successfully`
2. **Close and reopen** Server Manager (the Deployment Properties dialog shows cached data), then check **Tasks → Edit Deployment Properties → Certificates**.
3. Open the web client in a **private browser window**. Browsers can cache the old certificate.

You can also check the certificates from PowerShell on any server:

```powershell
Get-RDCertificate -ConnectionBroker <broker FQDN> | Format-Table Role, Level, ExpiresOn, Thumbprint
```

## Troubleshooting

| Log message | Cause / fix |
|---|---|
| No entries for today | The script didn't run. In win-acme, check that the renewal's installation steps include the script. |
| `No valid Let's Encrypt certificate found in ...` | No valid certificate in the Web Hosting or Personal store. Check win-acme's output for the renewal. |
| `Cannot export ... key` / export error | `PrivateKeyExportable` wasn't set when the certificate was issued. Set it (setup step 2) and force a renewal. |
| `Could not detect the Connection Broker` | The line above shows why. Usually access denied: complete setup step 3. Or pass the broker manually (see below). |
| `A Remote Desktop Services deployment does not exist on ...` | The broker detected (or passed) is wrong. Pass `-ConnectionBroker` with the correct broker FQDN. |
| Web client `skipped` | The web client isn't installed on that server. This is expected at sites without the web client. |

Note: a manual forced renewal runs as your account. It doesn't prove the automatic renewal (running as SYSTEM) will work. Setup step 3 is what makes that work.

## Optional parameters

For sites that don't fit the standard setup, enter these in win-acme's **Parameters** prompt:

| Parameter | Use when |
|---|---|
| `-ConnectionBroker broker.domain.local` | Broker auto-detection fails, or the site has two brokers in a high-availability setup |
| `-Thumbprint '{CertThumbprint}'` | The server has more than one Let's Encrypt certificate. win-acme fills in the exact certificate. |
| `-PfxPath '{CacheFile}' -PfxPassword '{CachePassword}'` | Use win-acme's cached PFX instead of exporting from the store (no exportable key needed) |
| `-LogPath <path>` | Write the log somewhere other than `%ProgramData%\win-acme\` |

## Not covered

- **Two brokers in a high-availability setup:** not tested. Pass `-ConnectionBroker` if detection picks the wrong one.
- **Non-English Windows:** the "RDS Management Servers" group name is translated, so pass `-ConnectionBroker`.
- **Session host RDP listener certificates:** not changed, matching the manual Server Manager process.
- **Service restarts:** setting the Gateway certificate can briefly drop sessions connected through the gateway. Renewals happen about 30 days before expiry, so you can move win-acme's scheduled task out of hours if needed.

## Don't commit

- win-acme's `settings.json` or renewal files (they hold the Cloudflare API token details)
- log files from `%ProgramData%\win-acme\` (certificate thumbprints and server names)
