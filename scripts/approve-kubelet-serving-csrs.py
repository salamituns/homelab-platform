#!/usr/bin/env python3
"""Approve pending kubelet *serving* CSRs, but only the ones a node may legitimately ask for (ADR 0009).

Kubernetes never auto-approves kubernetes.io/kubelet-serving CSRs: a node can put ANY name or IP in
its request, and an approved certificate for, say, the API server's IP would let that node
impersonate it. So every request is compared with what the cluster already knows about the node.

Usage: scripts/approve-kubelet-serving-csrs.py [--dry-run]
"""
import base64
import json
import subprocess
import sys

SIGNER = "kubernetes.io/kubelet-serving"


def kubectl_json(*args):
    return json.loads(subprocess.run(["kubectl", *args, "-o", "json"], check=True,
                                     capture_output=True, text=True).stdout)


def csr_sans(csr):
    """Names and IPs inside the certificate request, read with openssl (no extra Python packages)."""
    pem = base64.b64decode(csr["spec"]["request"])
    text = subprocess.run(["openssl", "req", "-noout", "-text"], input=pem, check=True,
                          capture_output=True).stdout.decode()
    dns, ips = set(), set()
    if "Subject Alternative Name:" not in text:
        return dns, ips
    san_line = text.split("Subject Alternative Name:", 1)[1].splitlines()[1]
    for item in san_line.split(","):
        kind, _, value = item.strip().partition(":")
        if kind == "DNS":
            dns.add(value)
        elif kind == "IP Address":
            ips.add(value)
    return dns, ips


def known_nodes():
    """{node name: {"dns": {...}, "ips": {...}}} from the Node objects' status.addresses."""
    nodes = {}
    for n in kubectl_json("get", "nodes")["items"]:
        addrs = n["status"]["addresses"]
        nodes[n["metadata"]["name"]] = {
            "dns": {a["address"] for a in addrs if a["type"] == "Hostname"},
            "ips": {a["address"] for a in addrs if a["type"] in ("InternalIP", "ExternalIP")},
        }
    return nodes


def reject_reason(username, dns, ips, nodes):
    """Return None if this CSR is safe to approve, otherwise a short reason to print.

    username: who sent the CSR, e.g. "system:node:workernode1" (set by the API server, cannot be faked)
    dns, ips: the names and IPs the node asks to be in its certificate
    nodes:    known_nodes(), the cluster's own record of each node's hostname and IPs
    """
    prefix = "system:node:"
    if not username.startswith(prefix):
        return f"sent by {username}, not by a node"
    node = nodes.get(username[len(prefix):])
    if node is None:
        return "sent by a node the cluster does not know"
    if not ips:
        return "no IP in the request: metrics-server connects by IP"
    # Only the sender's OWN names: workernode1 must not get a certificate for the master's IP
    if not dns <= node["dns"]:
        return f"asks for names that are not this node's: {sorted(dns - node['dns'])}"
    if not ips <= node["ips"]:
        return f"asks for IPs that are not this node's: {sorted(ips - node['ips'])}"
    return None


def main():
    dry_run = "--dry-run" in sys.argv
    nodes = known_nodes()
    pending = [c for c in kubectl_json("get", "csr")["items"]
               if c["spec"]["signerName"] == SIGNER and not c.get("status", {}).get("conditions")]
    if not pending:
        print("No pending kubelet-serving CSRs.")
    for csr in pending:
        name, user = csr["metadata"]["name"], csr["spec"]["username"]
        dns, ips = csr_sans(csr)
        reason = reject_reason(user, dns, ips, nodes)
        print(f"{name}  {user}  DNS={sorted(dns)} IP={sorted(ips)}  ->  {reason or 'OK'}")
        if reason is None and not dry_run:
            subprocess.run(["kubectl", "certificate", "approve", name], check=True)
        # A rejected CSR is left pending, not denied: look at it, then `kubectl certificate deny` by hand.


if __name__ == "__main__":
    main()
