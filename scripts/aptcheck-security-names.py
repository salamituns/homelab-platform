#!/usr/bin/env python3
# Same rules as /usr/lib/update-notifier/apt_check.py, but prints the package names it counts as security.
import sys, socket
sys.path.insert(0, "/usr/lib/update-notifier")
import apt_pkg
import apt_check as ac
apt_pkg.init()
cache = apt_pkg.Cache(None)
depcache = apt_pkg.DepCache(cache)
ac.saveDistUpgrade(cache, depcache)
host = socket.gethostname()
hits = []
for pkg in cache.packages:
    if not (depcache.marked_install(pkg) or depcache.marked_upgrade(pkg)):
        continue
    inst = pkg.current_ver
    cand = depcache.get_candidate_ver(pkg)
    if cand == inst:
        continue
    if ac.isSecurityUpgrade(cand):
        hits.append((pkg.name, inst.ver_str if inst else "-", cand.ver_str, "candidate is security"))
        continue
    for ver in pkg.version_list:
        if inst and apt_pkg.version_compare(ver.ver_str, inst.ver_str) <= 0:
            continue
        if ac.isSecurityUpgrade(ver):
            hits.append((pkg.name, inst.ver_str if inst else "-", ver.ver_str, "security fix masked by -updates " + cand.ver_str))
            break
for h in hits:
    print(f"{host}: {h[0]}  installed {h[1]} -> {h[2]}  ({h[3]})")
print(f"{host}: {len(hits)} counted as security")
