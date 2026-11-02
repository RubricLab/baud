#!/usr/bin/env python3
# Prunes stale UPnP mappings left by peer nodes on this machine. iroh asks the gateway for a new
# external port on every start and never releases the old one, so a box that restarts nodes
# fills its router's table (about 64 entries) until no mapping is granted. Deletes only mappings
# described "iroh-portmap" whose internal client is one of this machine's addresses and whose
# internal port no running process has bound: a mapping a live node can be using is kept.
# `--list` prints the table, `--count` the entries of ours for this machine; neither changes
# anything. `--probe` asks for a 60 s test mapping, asks whether the gateway holds it, removes it,
# and prints "stores", "says yes, stores nothing" or "refuses". scripts/bench.sh runs it on the remote.
import re, socket, subprocess, sys, urllib.request
from urllib.parse import urljoin

def discover():
    msg = "\r\n".join(["M-SEARCH * HTTP/1.1", "HOST: 239.255.255.250:1900", 'MAN: "ssdp:discover"', "MX: 2", "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1", "", ""]).encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    s.sendto(msg, ("239.255.255.250", 1900))
    while True:
        data, _ = s.recvfrom(4096)
        m = re.search(rb"(?i)location:\s*(\S+)", data)
        if m:
            return m.group(1).decode()

def control(location):
    xml = urllib.request.urlopen(location, timeout=5).read().decode()
    for svc in ("WANIPConnection:2", "WANIPConnection:1", "WANPPPConnection:1"):
        st = "urn:schemas-upnp-org:service:" + svc
        i = xml.find(st)
        if i >= 0:
            m = re.search(r"<controlURL>([^<]+)</controlURL>", xml[i:])
            return urljoin(location, m.group(1)), st
    raise SystemExit("no WAN connection service")

def call(url, st, action, args):
    body = "".join(f"<{k}>{v}</{k}>" for k, v in args.items())
    env = f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:{action} xmlns:u="{st}">{body}</u:{action}></s:Body></s:Envelope>'
    req = urllib.request.Request(url, data=env.encode(), headers={"Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{st}#{action}"'})
    return urllib.request.urlopen(req, timeout=5).read().decode()


if "--probe" in sys.argv:
    # What the gateway does with a mapping: the bench's phantom row says which router it met.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("192.0.2.1", 9))
    me = s.getsockname()[0]
    url, st = control(discover())
    port = {"NewRemoteHost": "", "NewExternalPort": 45999, "NewProtocol": "TCP"}
    try:
        call(url, st, "AddPortMapping", {**port, "NewInternalPort": 45999, "NewInternalClient": me, "NewEnabled": 1, "NewPortMappingDescription": "peer-probe", "NewLeaseDuration": 60})
    except Exception:
        print("refuses")
        sys.exit(0)
    try:
        x = call(url, st, "GetSpecificPortMappingEntry", port)
        held = f"<NewInternalClient>{me}</NewInternalClient>" in x
    except Exception:
        held = False
    try:
        call(url, st, "DeletePortMapping", port)
    except Exception:
        pass
    print("stores" if held else "says yes, stores nothing")
    sys.exit(0)

if "--count" in sys.argv:
    # Entries of ours for this machine, live or not: the bench's before/after assertion.
    mine = set(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", subprocess.run(["ifconfig"], capture_output=True, text=True).stdout))
    loc = discover()
    url, st = control(loc)
    n = 0
    for i in range(256):
        try:
            x = call(url, st, "GetGenericPortMappingEntry", {"NewPortMappingIndex": i})
        except Exception:
            break
        g = lambda t: (re.search(rf"<{t}>([^<]*)</{t}>", x) or [None, ""])[1]
        if g("NewPortMappingDescription") in ("iroh-portmap", "peer") and g("NewInternalClient") in mine:
            n += 1
    print(n)
    sys.exit(0)

if "--list" in sys.argv:
    loc = discover()
    url, st = control(loc)
    for i in range(256):
        try:
            x = call(url, st, "GetGenericPortMappingEntry", {"NewPortMappingIndex": i})
        except Exception:
            break
        g = lambda t: (re.search(rf"<{t}>([^<]*)</{t}>", x) or [None, ""])[1]
        print(g("NewExternalPort"), g("NewProtocol"), g("NewInternalClient"), g("NewInternalPort"), g("NewLeaseDuration"), g("NewPortMappingDescription"))
    sys.exit(0)

mine = set(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", subprocess.run(["ifconfig"], capture_output=True, text=True).stdout))
bound = set()
out = subprocess.run(["lsof", "-nP", "-iUDP", "-iTCP"], capture_output=True, text=True).stdout
for line in out.splitlines()[1:]:
    m = re.search(r":(\d+)(?:->|\s|$)", line.split()[8] if len(line.split()) > 8 else "")
    if m:
        bound.add(m.group(1))
loc = discover()
url, st = control(loc)
rows = []
for i in range(256):
    try:
        x = call(url, st, "GetGenericPortMappingEntry", {"NewPortMappingIndex": i})
    except Exception:
        break
    g = lambda t: (re.search(rf"<{t}>([^<]*)</{t}>", x) or [None, ""])[1]
    rows.append((g("NewExternalPort"), g("NewProtocol"), g("NewInternalClient"), g("NewInternalPort"), g("NewPortMappingDescription")))
gone = 0
for ext, proto, client, port, desc in rows:
    if desc in ("iroh-portmap", "peer") and client in mine and port not in bound:
        call(url, st, "DeletePortMapping", {"NewRemoteHost": "", "NewExternalPort": ext, "NewProtocol": proto})
        print("deleted", ext, proto, client, port)
        gone += 1
print(len(rows), "mappings,", gone, "stale deleted; bound ports kept:", " ".join(sorted(bound, key=int)))
