"""Embed and sign the pinned Sparkle runtime without exposing signing secrets."""
import base64
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORK = ROOT / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
PUBLIC_KEY = ROOT / "Support" / "SparklePublicKey.txt"
FEED_URL = "https://storagedaddy.significanthobbies.com/updates/appcast.xml"

def configuration():
    if not PUBLIC_KEY.is_file():
        raise RuntimeError("Sparkle signing is not configured. Generate a dedicated Keychain key with Sparkle's generate_keys --account storagedaddy-updates, then save ONLY its public key to Support/SparklePublicKey.txt.")
    key = PUBLIC_KEY.read_text().strip()
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Sparkle public key must decode to 32 bytes")
    return {"SUFeedURL": FEED_URL, "SUPublicEDKey": key,
            "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False,
            "SUAllowsAutomaticUpdates": False, "SUSendProfileInfo": False,
            "SUVerifyUpdateBeforeExtraction": True}

def embed(app):
    if not FRAMEWORK.is_dir():
        raise RuntimeError("Resolve pinned Sparkle package before packaging")
    target = app / "Contents/Frameworks/Sparkle.framework"
    # Replace the complete framework, preserving symlinks and executable modes.
    if target.exists():
        import uuid
        backup = ROOT / "artifacts" / ("Sparkle.previous-" + uuid.uuid4().hex + ".framework")
        backup.parent.mkdir(exist_ok=True)
        target.rename(backup)
    shutil.copytree(FRAMEWORK, target, symlinks=True)
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / ".build/artifacts/sparkle/Sparkle/LICENSE", resources / "Sparkle-LICENSE.txt")
    return target

def sign(app, identity, timestamp=True):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    version = framework / "Versions/B"
    targets = [version / "XPCServices/Downloader.xpc", version / "XPCServices/Installer.xpc",
               version / "Autoupdate", version / "Updater.app", framework]
    for target in targets:
        if not target.exists():
            raise RuntimeError(f"Missing Sparkle component: {target.name}")
        command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
        if timestamp:
            command.append("--timestamp")
        subprocess.run(command + [str(target)], check=True)
