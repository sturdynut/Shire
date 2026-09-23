# Shire logo

<img src="shire-logo-transparent.png" width="200" alt="Shire logo: a green hill shelter with two silver server drawers and green status lights">

A green hill shelter around two server drawers with healthy green lights: a safe little home for services that are
always running. The name is the shelter; green is the colour Shire already uses for "healthy".

## Files

| File | Use |
|---|---|
| `shire-logo-transparent.png` | **The logo.** Transparent background, 1254×1254. Source for every icon. |
| `shire-logo-warm-v2.png` | The same mark on a warm ivory tile; the approved concept it was cut from. |
| `shire-logo.png` | An earlier concept (charcoal tile, green arch), not used. |
| `logo-prompt*.txt` | The image-generation prompts behind each file. |

## Where it's used

- Shire.app's icon (also shown on its notifications), built from the logo by `App/build-icon.sh` during `make app`.
- `Sources/ShireCore/Phone/PhoneIcons.swift`: the phone page's Home Screen icon (180×180) and manifest icon
  (512×512), drawn on warm ivory because iOS shows transparent icon areas as black.
- The top of the repository README.

After changing the logo, `make app` rebuilds the app icon and `make icons` regenerates the phone icons.
