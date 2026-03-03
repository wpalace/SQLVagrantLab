# Testing and Configuring the Lab

This document outlines the procedures for interacting with and validating the components of the SQL Vagrant Lab after deployment.

## Connecting to SQL Server

By default, the SQL Server instance `sql01` is not exposed to the VM host's NAT network, as it relies entirely on the host bridge topology (`10.0.50.x`). To connect to the SQL Server from your VM host, we must establish an SSH local port forward.

### 1. Establish an SSH Tunnel

Run the following command to forward the local port `51433` on your host to the SQL Server's default port `1433` over the SSH bridge connection:

```bash
sshpass -p vagrant ssh -N -f -L 51433:127.0.0.1:1433 vagrant@10.0.50.20 -o StrictHostKeyChecking=no
```

- **`-N`**: Tells SSH not to execute a remote command (port forwarding only).
- **`-f`**: Runs the SSH session in the background so you can continue using your terminal.

*(Note: To kill the background forward later, you can find its process ID with `ps -ef | grep 51433` and use `kill <PID>`)*

### 2. Verify Connectivity using dbatools

With the tunnel established, we can use the `dbatools` PowerShell module (installed on the host via `Install-Prerequisites.ps1`) to query the instance at `127.0.0.1,51433`. The default authentication uses SQL Authentication with the `sa` account.

Run this PowerShell command on your host:

```powershell
# Authenticate with the default 'sa' password and query the instance version
$cred = New-Object System.Management.Automation.PSCredential("sa", (ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force))

# Connect to the loopback forwarded port and execute query
Connect-DbaInstance -SqlInstance "127.0.0.1,51433" -SqlCredential $cred -TrustServerCertificate | Invoke-DbaQuery -Query "SELECT @@SERVERNAME as ServerName, @@VERSION as Version" | ft -wrap -autosize
```

If successful, you will see output similar to the following, confirming SQL Server is successfully responding to queries:

```text
ServerName Version
---------- -------
sql01      Microsoft SQL Server 2022 (RTM) - 16.0.1000.6 (X64)...
```
