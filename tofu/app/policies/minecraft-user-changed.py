event = context.get("event")
if not event:
    return False
model = event.context.get("model", {})
return model.get("app") == "authentik_core" and model.get("model_name") == "user"
