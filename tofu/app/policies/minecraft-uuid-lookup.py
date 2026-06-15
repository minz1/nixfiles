import json as _json
import urllib.error as _urlerr
import urllib.request as _urlreq

username = str(
    context.get("prompt_data", {}).get("attributes", {}).get("minecraft_username", "")
).strip()
if not username:
    return True

ak_logger.info(f"Querying Mojang API for {username!r}")
try:
    req = _urlreq.Request(
        f"https://api.mojang.com/users/profiles/minecraft/{username}",
        headers={"User-Agent": "Authentik-Minecraft-Link/1.0"},
    )
    with _urlreq.urlopen(req, timeout=10) as resp:
        if resp.status == 204:
            ak_message(f"'{username}' is not a valid Minecraft username.")
            return False
        data = _json.loads(resp.read())
except _urlerr.HTTPError as e:
    if e.code == 404:
        ak_message(f"'{username}' is not a valid Minecraft username.")
        return False
    ak_logger.warning(f"Mojang API returned {e.code}")
    ak_message("Could not verify Minecraft username. Please try again later.")
    return False
except Exception as e:
    ak_logger.warning(f"Mojang API error: {e}")
    ak_message("Could not reach Mojang API. Please try again later.")
    return False

raw = data["id"]
uuid = f"{raw[0:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:]}"
ak_logger.info(f"Resolved {username!r} -> {uuid}")

context["prompt_data"].setdefault("attributes", {})
context["prompt_data"]["attributes"]["minecraft_uuid"] = uuid
context["prompt_data"]["attributes"]["minecraft_username"] = data["name"]
return True
