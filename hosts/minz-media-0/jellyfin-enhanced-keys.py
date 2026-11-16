import json
import os
import sys
import xml.etree.ElementTree as ET

CONFIG = (
    "/var/lib/jellyfin/plugins/configurations/"
    "Jellyfin.Plugin.JellyfinEnhanced.xml"
)
SEERR_SETTINGS = "/var/lib/private/seerr/settings.json"
NAMESPACES = {
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    "xsd": "http://www.w3.org/2001/XMLSchema",
}


def read_secret(name):
    with open(f"/run/secrets/{name}") as f:
        return f.read().strip()


def set_text(root, tag, value):
    el = root.find(tag)
    if el is None:
        return False
    if el.text == value:
        return False
    el.text = value
    return True


def set_instance_keys(root, tag, value):
    el = root.find(tag)
    if el is None or not (el.text or "").strip():
        return False
    instances = json.loads(el.text)
    changed = False
    for inst in instances:
        if inst.get("ApiKey") != value:
            inst["ApiKey"] = value
            changed = True
    if changed:
        el.text = json.dumps(instances, separators=(",", ":"))
    return changed


def main():
    if not os.path.exists(CONFIG):
        print("jellyfin-enhanced-keys: no plugin config yet, skipping")
        return 0
    for prefix, uri in NAMESPACES.items():
        ET.register_namespace(prefix, uri)
    tree = ET.parse(CONFIG)
    root = tree.getroot()
    sonarr = read_secret("sonarr_api_key")
    radarr = read_secret("radarr_api_key")
    with open(SEERR_SETTINGS) as f:
        seerr = json.load(f)["main"]["apiKey"]
    changes = [
        set_text(root, "JellyseerrApiKey", seerr),
        set_text(root, "SonarrApiKey", sonarr),
        set_text(root, "RadarrApiKey", radarr),
        set_instance_keys(root, "SonarrInstances", sonarr),
        set_instance_keys(root, "RadarrInstances", radarr),
    ]
    if not any(changes):
        print("jellyfin-enhanced-keys: keys already current")
        return 0
    st = os.stat(CONFIG)
    tmp = CONFIG + ".tmp"
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, CONFIG)
    print(f"jellyfin-enhanced-keys: updated {sum(changes)} key field(s)")
    return 0


sys.exit(main())
